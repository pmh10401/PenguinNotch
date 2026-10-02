import Foundation

enum StockEvaluationSource: String, Codable, Hashable, Sendable {
    case recorded, pairedCalculation, replay
}

struct StockEvaluationRow: Codable, Equatable, Sendable {
    struct Reference: Codable, Hashable, Sendable {
        let referenceID: String
        let source: StockEvaluationSource
    }
    var referenceID: String
    var source: StockEvaluationSource
    var inputKey: String?
    var stockID: String
    var currency: String
    var model: String
    var capture: String
    var sessionStart: Int64
    var inputPrice: Decimal
    var previousClose: Decimal
    var expectedClose: Decimal
    var lowerClose: Decimal?
    var upperClose: Decimal?
    var riseProbability: Double?
    var actualClose: Decimal?
    // References locate the unchanged journal/analysis; no evidence or response is copied here.
    var references: [Reference] = []
}

struct StockEvaluationMetrics: Codable {
    let total: Int
    let evaluated: Int
    let directionCount: Int
    let directionHits: Int
    let mape: Double?
    let baselineMAPE: Double?
    let brier: Double?
    let coverage: Double?
    let meanWidthPercent: Double?
    let maeByCurrency: [String: Double]
}

struct StockEvaluationComparison {
    struct Row {
        let model: String
        let available: StockEvaluationMetrics
        let paired: StockEvaluationMetrics
    }
    let rows: [Row]
    let pairedCount: Int
    let excludedConflicts: Int
    let excludedMissingEvidence: Int
}

enum StockEvaluation {
    /// inputSHA256 must be the receipt of the SAME archive.loadCase body decoded by the caller.
    static func replayRows(runID: UUID, caseData: StockBacktestCase, result: StockBacktestResult,
                           inputSHA256: String) throws -> [StockEvaluationRow] {
        try StockBacktestArchive.validateResult(result)
        guard caseData.isValid, result.caseID == caseData.input.caseID, result.inputSHA256 == inputSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let i = caseData.input, key = "\(runID.uuidString.lowercased())/\(i.caseID)/\(inputSHA256)"
        return result.outcomes.compactMap { o in
            guard let f = o.forecast else { return nil }
            return StockEvaluationRow(referenceID: key, source: .replay, inputKey: key, stockID: i.stockID,
                currency: i.currency, model: o.model, capture: "replay", sessionStart: i.sessionStart,
                inputPrice: i.inputPrice, previousClose: i.previousClose, expectedClose: f.expectedClose,
                lowerClose: f.lowerClose, upperClose: f.upperClose, riseProbability: f.riseProbability,
                actualClose: caseData.target.actualClose, references: [.init(referenceID: key, source: .replay)])
        }
    }

    static func calibration(_ rows: [StockEvaluationRow]) -> [StockForecastCalibration] {
        let valid = coalesced(rows).filter { row in
            row.actualClose.map(StockBacktest.positive) == true && StockBacktest.positive(row.previousClose)
                && row.riseProbability.map { $0.isFinite && (0...1).contains($0) } == true
        }
        let groups = Dictionary(grouping: valid) { min(9, Int($0.riseProbability! * 10)) }
        return groups.keys.sorted().map { id in
            let rows = groups[id]!
            return StockForecastCalibration(id: id, count: rows.count,
                rises: rows.filter { $0.actualClose! > $0.previousClose }.count,
                meanProbability: rows.reduce(0) { $0 + $1.riseProbability! } / Double(rows.count))
        }
    }

    static func filtered(_ rows: [StockEvaluationRow], market: String? = nil, stockID: String? = nil,
                         day: String? = nil, capture: String? = nil, source: StockEvaluationSource? = nil) -> [StockEvaluationRow] {
        rows.filter { row in
            guard let stock = WatchedStock.parse(row.stockID) else { return false }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = StockQuoteCodec.timeZone(for: stock.market)
            return (market == nil || stock.market.rawValue == market) && (stockID == nil || row.stockID == stockID)
                && (day == nil || StockBacktest.day(StockBacktest.date(row.sessionStart), calendar: calendar) == day)
                && (capture == nil || row.capture == capture) && (source == nil || row.source == source)
        }
    }

    struct ReplaySummary {
        struct Model {
            let model: String
            let success: Int
            let skipped: Int
            let pending: Int
            let unavailable: Int
            let metrics: StockEvaluationMetrics
            let calibration: [StockForecastCalibration]
        }
        let rows: [StockEvaluationRow]
        let requested: Int
        let acquired: Int
        let pending: Int
        let skipped: Int
        let unavailable: Int
        let stockCount: Int
        let dayCount: Int
        let comparison: StockEvaluationComparison
        let models: [Model]
    }

    /// Acquisition denominators come from the manifest, never from invented forecast rows.
    static func replaySummary(manifest: StockBacktestManifest, loaded: [StockBacktestLoadedCase], selectedModels: Set<String>,
                              market: String? = nil, stockID: String? = nil, day: String? = nil) throws -> ReplaySummary {
        try replaySummary(manifest: manifest, receipts: loaded.map { try StockBacktestReceipt(runID: manifest.runID, loaded: $0) },
                          selectedModels: selectedModels, market: market, stockID: stockID, day: day)
    }
    static func replaySummary(manifest: StockBacktestManifest, receipts loaded: [StockBacktestReceipt], selectedModels: Set<String>,
                              market: String? = nil, stockID: String? = nil, day: String? = nil) throws -> ReplaySummary {
        guard selectedModels.isSubset(of: Set(manifest.models)), Set(loaded.map { $0.entry.caseID }).count == loaded.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let entries = manifest.cases.filter { e in
            (market == nil || WatchedStock.parse(e.stockID)?.market.rawValue == market)
                && (stockID == nil || e.stockID == stockID) && (day == nil || e.tradingDay == day)
        }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.entry.caseID, $0) })
        var rows: [StockEvaluationRow] = [], skips: [String: Int] = [:], unavailable = 0
        for e in entries where e.status == .saved {
            guard let c = byID[e.caseID] else { unavailable += 1; continue }
            guard c.runID == manifest.runID, c.entry == e, c.inputSHA256 == e.inputSHA256 else { throw CocoaError(.fileReadCorruptFile) }
            guard let outcomes = c.outcomes else { unavailable += 1; continue }
            guard c.resultSHA256 == e.resultSHA256, e.resultSHA256 != nil,
                  Set(outcomes.map(\.model)) == Set(manifest.models) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            rows += c.rows
            for o in outcomes where o.status == .skipped { skips[o.model, default: 0] += 1 }
        }
        rows = rows.filter { selectedModels.contains($0.model) }
        let pending = entries.filter { $0.status == .pending }.count
        return ReplaySummary(rows: rows, requested: entries.count, acquired: entries.filter { $0.status == .saved }.count,
            pending: pending, skipped: entries.filter { $0.status == .skipped }.count, unavailable: unavailable,
            stockCount: Set(entries.map(\.stockID)).count, dayCount: Set(entries.map(\.tradingDay)).count,
            comparison: compare(rows, selectedModels: selectedModels), models: selectedModels.sorted().map { model in
                let own = rows.filter { $0.model == model }
                return .init(model: model, success: own.count, skipped: skips[model, default: 0], pending: pending,
                    unavailable: unavailable, metrics: metrics(own), calibration: calibration(own))
            })
    }

    /// Details are verified original public JSON, including manifest entries and skipped outcomes.
    static func csv(rows: [StockEvaluationRow], metrics: StockEvaluationMetrics, details: [String: String]) -> String {
        let header = ["type", "referenceID", "source", "inputKey", "stockID", "market", "tradingDay", "currency", "model", "capture",
            "sessionStart", "inputPrice", "previousClose", "expectedClose", "lowerClose", "upperClose", "riseProbability", "actualClose",
            "status", "reason", "priceBasis", "references", "rawDetail", "total", "evaluated", "directionCount", "directionHits",
            "probabilityCount", "rangeCount", "mape", "baselineMAPE", "brier", "coverage", "meanWidthPercent", "maeByCurrency", "limitation"]
        let numeric = Set(header[10...17] + header[23...33])
        func text(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func number(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func line(_ values: [String: String]) -> String { header.map { numeric.contains($0) ? values[$0, default: ""] : text(values[$0, default: ""]) }.joined(separator: ",") }
        var lines = [header.joined(separator: ",")]
        for row in coalesced(rows) {
            let stock = WatchedStock.parse(row.stockID)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = StockQuoteCodec.timeZone(for: stock?.market ?? .us)
            var values = ["type": "forecast", "referenceID": row.referenceID, "source": row.source.rawValue,
                "inputKey": row.inputKey ?? "", "stockID": row.stockID, "market": stock?.market.rawValue ?? "",
                "tradingDay": StockBacktest.day(StockBacktest.date(row.sessionStart), calendar: calendar), "currency": row.currency,
                "model": row.model, "capture": row.capture, "sessionStart": String(row.sessionStart), "inputPrice": number(row.inputPrice),
                "previousClose": number(row.previousClose), "expectedClose": number(row.expectedClose), "lowerClose": number(row.lowerClose),
                "upperClose": number(row.upperClose), "riseProbability": row.riseProbability.map { String($0) } ?? "", "actualClose": number(row.actualClose),
                "status": row.actualClose == nil ? "pending" : "evaluated", "reason": row.actualClose == nil ? "awaiting_actual" : "",
                "references": json(row.references), "rawDetail": details[row.referenceID] ?? ""]
            values["priceBasis"] = row.source == .replay ? StockBacktest.priceBasis : "original-record-evidence"
            values["limitation"] = row.source == .replay ? "Reconstructed from currently fetched data; historical information vintage is not guaranteed" : ""
            lines.append(line(values))
        }
        // Separate detail rows retain acquisition skips/abstentions even when no forecast exists.
        for id in details.keys.sorted() {
            let raw = details[id]!
            let detail = (try? StockBacktest.jsonObject(Data(raw.utf8))) as? [String: Any]
            let entry = detail?["entry"] as? [String: Any]
            let unavailable = entry?["status"] as? String == "saved" && !(detail?["resultBody"] is String)
            lines.append(line(["type": "detail", "referenceID": id, "rawDetail": raw,
                "status": entry?["status"] as? String ?? "", "reason": unavailable ? "result_unavailable" : entry?["reason"] as? String ?? ""]))
            if let body = detail?["resultBody"] as? String, let result = try? StockBacktestArchive.decodeResult(Data(body.utf8)) {
                for outcome in result.outcomes {
                    lines.append(line(["type": "outcome", "referenceID": id, "source": "replay", "model": outcome.model,
                        "status": outcome.status.rawValue, "reason": outcome.reason ?? ""]))
                }
            }
        }
        let done = coalesced(rows).filter { $0.actualClose.map(StockBacktest.positive) == true }
        var values = ["type": "metrics", "total": String(metrics.total), "evaluated": String(metrics.evaluated),
            "directionCount": String(metrics.directionCount), "directionHits": String(metrics.directionHits),
            "probabilityCount": String(done.filter { $0.riseProbability != nil }.count),
            "rangeCount": String(done.filter { $0.lowerClose != nil && $0.upperClose != nil }.count), "maeByCurrency": json(metrics.maeByCurrency)]
        for (key, value) in [("mape", metrics.mape), ("baselineMAPE", metrics.baselineMAPE), ("brier", metrics.brier),
                             ("coverage", metrics.coverage), ("meanWidthPercent", metrics.meanWidthPercent)] { values[key] = value.map { String($0) } ?? "" }
        lines.append(line(values))
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private struct Input: Hashable {
        let key: String?
        let stockID: String
        let currency: String
        let capture: String
        let sessionStart: Int64
        let inputPrice: Decimal
        let previousClose: Decimal
        let replay: Bool

        init(_ row: StockEvaluationRow) {
            key = row.inputKey
            stockID = row.stockID
            currency = row.currency
            capture = row.capture
            sessionStart = row.sessionStart
            inputPrice = row.inputPrice
            previousClose = row.previousClose
            replay = row.source == .replay
        }
    }

    static func rows(journal: [StockForecastRecord], analyses: [StockCodexAnalysis]) -> [StockEvaluationRow] {
        var result = journal.compactMap { row($0, source: .recorded, referenceID: $0.id) }
        for analysis in analyses {
            guard analysis.promptVersion == StockCodexAnalysis.promptVersion,
                  analysis.input.isFresh(at: analysis.createdAt), analysis.input.isFresh(at: analysis.completedAt),
                  analysis.createdAt <= analysis.completedAt,
                  let forecast = analysis.forecastRecord, forecast.isValid,
                  let paired = analysis.pairedGBMRecord, paired.isValid else { continue }
            result += [row(forecast, source: .recorded, referenceID: analysis.id.uuidString),
                       row(paired, source: .pairedCalculation, referenceID: analysis.id.uuidString)].compactMap { $0 }
        }
        return coalesced(result)
    }

    private static func milliseconds(_ date: Date) -> Double? {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return value
    }

    private static func row(_ record: StockForecastRecord, source: StockEvaluationSource,
                            referenceID: String) -> StockEvaluationRow? {
        // Normalize only the published row timestamp; the frozen key below keeps the original clock.
        guard record.isValid, let start = milliseconds(record.sessionStart), let sessionStart = Int64(exactly: start.rounded(.towardZero)),
              let end = milliseconds(record.sessionEnd), let quote = milliseconds(record.quoteAt) else { return nil }
        var key: String?
        if let evidence = record.evidence {
            var closes: [[Any]] = []
            for close in evidence.closes {
                guard let date = milliseconds(close.date) else { return nil }
                closes.append([date, NSDecimalNumber(decimal: close.price)])
            }
            let input: [Any] = [record.stockID, record.currency, record.capture.rawValue, quote, start, end,
                                NSDecimalNumber(decimal: record.previousClose), NSDecimalNumber(decimal: record.inputPrice),
                                evidence.adjusted, closes,
                                // Epoch-ms conversion can lose one Date ULP; preserve native clocks in the opaque key.
                                [String(record.quoteAt.timeIntervalSinceReferenceDate),
                                 String(record.sessionStart.timeIntervalSinceReferenceDate),
                                 String(record.sessionEnd.timeIntervalSinceReferenceDate),
                                 evidence.closes.map { String($0.date.timeIntervalSinceReferenceDate) }]]
            guard let data = try? JSONSerialization.data(withJSONObject: input, options: .withoutEscapingSlashes) else { return nil }
            key = String(decoding: data, as: UTF8.self)
        }
        return StockEvaluationRow(referenceID: referenceID, source: source, inputKey: key,
            stockID: record.stockID, currency: record.currency, model: record.model,
            capture: record.capture.rawValue, sessionStart: sessionStart, inputPrice: record.inputPrice,
            previousClose: record.previousClose, expectedClose: record.expectedClose,
            lowerClose: record.lowerClose, upperClose: record.upperClose, riseProbability: record.riseProbability,
            actualClose: record.actualClose, references: [.init(referenceID: referenceID, source: source)])
    }

    /// Only equivalent paired calculations merge; duplicate saved records stay ambiguous.
    static func coalesced(_ rows: [StockEvaluationRow]) -> [StockEvaluationRow] {
        var result: [StockEvaluationRow] = []
        var visited = Set<Int>()
        let groups = Dictionary(grouping: rows.indices, by: { Input(rows[$0]) })
        // ponytail: scans within each small model cohort; index by model if large duplicate imports dominate.
        for (index, row) in rows.enumerated() where !visited.contains(index) {
            let matches = groups[Input(row), default: []].filter { rows[$0].inputKey != nil && rows[$0].model == row.model }
            let group = matches.map { rows[$0] }
            let equivalent = group.allSatisfy { $0.expectedClose == row.expectedClose
                && $0.lowerClose == row.lowerClose && $0.upperClose == row.upperClose
                && $0.riseProbability == row.riseProbability && $0.actualClose == row.actualClose }
            if row.inputKey != nil, group.contains(where: { $0.source == .pairedCalculation }),
               group.filter({ $0.source == .recorded }).count <= 1, equivalent {
                var merged = group.first { $0.source == .recorded } ?? row
                merged.references = group.flatMap { item in
                    item.references.isEmpty ? [.init(referenceID: item.referenceID, source: item.source)] : item.references
                }
                result.append(merged)
                visited.formUnion(matches)
            } else { result.append(row) }
        }
        return result
    }

    private static func number(_ value: Decimal) -> Double? {
        let result = NSDecimalNumber(decimal: value).doubleValue
        return result.isFinite ? result : nil
    }

    // A failed calculation invalidates that aggregate metric, never contributes a perfect zero.
    private static func average(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0?.isFinite == true }) else { return nil }
        let result = values.reduce(0) { $0 + $1! / Double(values.count) }
        return result.isFinite ? result : nil
    }

    static func metrics(_ rows: [StockEvaluationRow]) -> StockEvaluationMetrics {
        let unique = coalesced(rows)
        let done = unique.filter { $0.actualClose.map { $0 > 0 && number($0) != nil } == true }
        let directions = done.filter { $0.riseProbability.map { $0.isFinite && (0...1).contains($0) && $0 != 0.5 } == true
            && $0.actualClose != $0.previousClose }
        let probability = done.filter { $0.riseProbability != nil }
        let ranges = done.filter { $0.lowerClose != nil && $0.upperClose != nil }
        let errors = Dictionary(grouping: done, by: \.currency).compactMapValues { rows in
            average(rows.map { number(abs($0.expectedClose - $0.actualClose!)) })
        }
        return StockEvaluationMetrics(total: unique.count, evaluated: done.count,
            directionCount: directions.count,
            directionHits: directions.filter { ($0.riseProbability! > 0.5) == ($0.actualClose! > $0.previousClose) }.count,
            mape: average(done.map { number(abs($0.expectedClose - $0.actualClose!) / $0.actualClose! * 100) }),
            baselineMAPE: average(done.map { number(abs($0.inputPrice - $0.actualClose!) / $0.actualClose! * 100) }),
            brier: average(probability.map { row in
                guard let p = row.riseProbability, p.isFinite, (0...1).contains(p) else { return nil }
                return pow(p - (row.actualClose! > row.previousClose ? 1 : 0), 2)
            }),
            coverage: average(ranges.map { $0.lowerClose! <= $0.actualClose! && $0.actualClose! <= $0.upperClose! ? 100 : 0 }),
            meanWidthPercent: average(ranges.map { number(($0.upperClose! - $0.lowerClose!) / $0.inputPrice * 100) }),
            maeByCurrency: errors)
    }

    static func compare(_ rows: [StockEvaluationRow], selectedModels: Set<String>) -> StockEvaluationComparison {
        let selected = coalesced(rows.filter { selectedModels.contains($0.model) })
        let missing = selected.filter { selectedModels.count > 1 && $0.inputKey == nil }
        let groups = Dictionary(grouping: selected.filter { selectedModels.count == 1 || $0.inputKey != nil }, by: Input.init)
        var matched: [StockEvaluationRow] = []
        var pairedCount = 0, conflicts = 0
        for group in groups.values {
            if Set(group.map(\.model)).count != group.count || Set(group.compactMap(\.actualClose)).count > 1 {
                conflicts += 1
                continue
            }
            guard Set(group.map(\.model)) == selectedModels, group.allSatisfy({ $0.actualClose != nil }) else { continue }
            pairedCount += 1
            matched += group
        }
        return StockEvaluationComparison(rows: selectedModels.sorted().map { model in
            .init(model: model, available: metrics(selected.filter { $0.model == model }),
                  paired: metrics(matched.filter { $0.model == model }))
        }, pairedCount: pairedCount, excludedConflicts: conflicts, excludedMissingEvidence: missing.count)
    }
}
