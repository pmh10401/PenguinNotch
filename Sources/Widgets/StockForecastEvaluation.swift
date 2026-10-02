import Foundation

enum StockEvaluationSource: String, Codable, Hashable {
    case recorded, pairedCalculation, replay
}

struct StockEvaluationRow: Codable, Equatable {
    struct Reference: Codable, Hashable {
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
        guard record.isValid, let start = milliseconds(record.sessionStart), let sessionStart = Int64(exactly: start),
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
