import Combine
import Foundation

enum ForecastCapture: String, Codable, CaseIterable, Identifiable {
    case scheduled, manual
    var id: String { rawValue }
    var title: String { L10n.t(self == .scheduled ? "About one hour before close" : "Saved manually") }
}

/// Inputs are immutable: subsequent quotes and model changes cannot rewrite a prediction.
/// This deliberately contains no account identifiers, quantities, or purchase prices.
struct StockForecastRecord: Codable, Identifiable {
    static let modelVersion = "GBM zero drift v1"
    let stockID: String
    let name: String
    let currency: String
    let model: String
    var capture: ForecastCapture
    let createdAt: Date
    let quoteAt: Date
    let sessionStart: Date
    let sessionEnd: Date
    let previousClose: Decimal
    let inputPrice: Decimal
    let expectedClose: Decimal
    let lowerClose: Decimal
    let upperClose: Decimal
    let riseProbability: Double
    let observations: Int
    let evidence: StockForecastEvidence?
    var actualClose: Decimal?
    var evaluatedAt: Date?

    var id: String { "\(stockID)|\(sessionStart.timeIntervalSince1970)|\(model)|\(capture.rawValue)" }
    var stock: WatchedStock? { WatchedStock.parse(stockID) }
    var marketCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockQuoteCodec.timeZone(for: stock?.market ?? .us)
        return calendar
    }
    var tradingDay: Date { marketCalendar.startOfDay(for: sessionStart) }
    // Daily candles have no final flag. Never score the still-open local calendar day.
    var evaluationAfter: Date { marketCalendar.date(byAdding: .day, value: 1, to: tradingDay)! }
    var directionHit: Bool? {
        guard let actualClose, actualClose != previousClose, riseProbability != 0.5 else { return nil }
        return (riseProbability > 0.5) == (actualClose > previousClose)
    }
    var absolutePercentageError: Double? {
        actualClose.map { abs(NSDecimalNumber(decimal: (expectedClose - $0) / $0).doubleValue) * 100 }
    }
    var baselineError: Double? {
        actualClose.map { abs(NSDecimalNumber(decimal: (inputPrice - $0) / $0).doubleValue) * 100 }
    }
    var rangeHit: Bool? { actualClose.map { lowerClose <= $0 && $0 <= upperClose } }
    var brierScore: Double? {
        actualClose.map { pow(riseProbability - ($0 > previousClose ? 1 : 0), 2) }
    }
    var isValid: Bool {
        stock?.id == stockID && !model.isEmpty && model.count <= 100
            && currency == (stock?.market == .kr ? "KRW" : "USD")
            && [previousClose, inputPrice, expectedClose, lowerClose, upperClose].allSatisfy {
                $0 > 0 && NSDecimalNumber(decimal: $0).doubleValue.isFinite
            }
            && lowerClose <= upperClose && (0...1).contains(riseProbability)
            && (20...60).contains(observations)
            && [createdAt, quoteAt, sessionStart, sessionEnd].allSatisfy { $0.timeIntervalSince1970.isFinite }
            && sessionStart <= createdAt && createdAt < sessionEnd
            && sessionStart <= quoteAt && quoteAt <= createdAt
            && createdAt.timeIntervalSince(quoteAt) <= 120
            && (capture != .scheduled || (3300...3600).contains(sessionEnd.timeIntervalSince(createdAt)))
            && (evidence.map { $0.isValid(for: self) } ?? true)
            && ((actualClose == nil && evaluatedAt == nil)
                || (actualClose.map { $0 > 0 && NSDecimalNumber(decimal: $0).doubleValue.isFinite } == true
                    && evaluatedAt.map { $0 >= evaluationAfter } == true))
    }
}

struct StockForecastScore {
    let total: Int
    let evaluated: Int
    let directionCount: Int
    let directionHits: Int
    let meanError: Double?
    let baselineError: Double?
    let rangeCoverage: Double?
    let brier: Double?

    init(_ records: [StockForecastRecord]) {
        total = records.count
        let completed = records.filter { $0.actualClose != nil }
        evaluated = completed.count
        let directions = completed.compactMap(\.directionHit)
        directionCount = directions.count
        directionHits = directions.filter { $0 }.count
        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        meanError = average(completed.compactMap(\.absolutePercentageError))
        baselineError = average(completed.compactMap(\.baselineError))
        rangeCoverage = average(completed.compactMap(\.rangeHit).map { $0 ? 100 : 0 })
        brier = average(completed.compactMap(\.brierScore))
    }
}

/// Every compared model must have the same information and the same resolved target.
/// Old records can still be compared with their own price-hold baseline, but their
/// missing candle inputs cannot establish a fair comparison with another model.
struct StockForecastComparison {
    struct Row: Identifiable {
        let model: String
        let available: StockForecastScore
        let paired: StockForecastScore
        var id: String { model }
    }
    private struct Inputs: Hashable {
        let stockID: String
        let currency: String
        let capture: String
        let quoteAt: Date
        let sessionStart: Date
        let sessionEnd: Date
        let previousClose: Decimal
        let inputPrice: Decimal
        let observations: Int
        let evidence: StockForecastEvidence?
    }
    let rows: [Row]
    let pairedCount: Int
    let baselineError: Double?

    init(_ records: [StockForecastRecord]) {
        let valid = records.filter(\.isValid)
        let models = Set(valid.map(\.model))
        let groups = Dictionary(grouping: valid.filter { $0.actualClose != nil && (models.count == 1 || $0.evidence != nil) }) {
            Inputs(stockID: $0.stockID, currency: $0.currency, capture: $0.capture.rawValue,
                   quoteAt: $0.quoteAt, sessionStart: $0.sessionStart, sessionEnd: $0.sessionEnd,
                   previousClose: $0.previousClose, inputPrice: $0.inputPrice,
                   observations: $0.observations, evidence: $0.evidence)
        }
        let matched = groups.values.filter {
            $0.count == models.count && Set($0.map(\.model)) == models
                && Set($0.compactMap(\.actualClose)).count == 1
        }
        pairedCount = matched.count
        let paired = matched.flatMap { $0 }
        baselineError = StockForecastScore(matched.compactMap(\.first)).baselineError
        rows = models.sorted().map { model in
            Row(model: model, available: StockForecastScore(valid.filter { $0.model == model }),
                paired: StockForecastScore(paired.filter { $0.model == model }))
        }
    }
}

/// Reliability bins describe observed frequencies; they never retune saved probabilities.
struct StockForecastCalibration: Identifiable {
    let id: Int
    let count: Int
    let rises: Int
    let meanProbability: Double
    var observedRate: Double { Double(rises) / Double(count) }
    var label: String { id == 9 ? "90–100%" : "\(id * 10)–<\((id + 1) * 10)%" }

    // Wilson 95% interval. Descriptive only: stocks/dates may be correlated.
    // Formula: https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm
    var interval: ClosedRange<Double> {
        let n = Double(count), z = 1.959963984540054
        let denominator = 1 + z * z / n
        let center = (observedRate + z * z / (2 * n)) / denominator
        let radius = z * sqrt(observedRate * (1 - observedRate) / n + z * z / (4 * n * n)) / denominator
        return max(0, center - radius)...min(1, center + radius)
    }

    static func bins(_ records: [StockForecastRecord]) -> [Self] {
        let completed = records.filter { $0.isValid && $0.actualClose != nil }
        let groups = Dictionary(grouping: completed) { min(9, Int($0.riseProbability * 10)) }
        return groups.keys.sorted().map { index in
            let records = groups[index]!
            return Self(id: index, count: records.count,
                        rises: records.filter { $0.actualClose! > $0.previousClose }.count,
                        meanProbability: records.reduce(0) { $0 + $1.riseProbability } / Double(records.count))
        }
    }
}

@MainActor
final class StockForecastJournal: ObservableObject {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PenguinNotch/Forecasts/history.json")
    }
    @Published private(set) var records: [StockForecastRecord] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var reconciliationMessage: String?
    private let url: URL?
    private var readFailed = false
    private var attempts: [String: Date] = [:]
    private struct Archive: Codable {
        var version = 1
        let records: [StockForecastRecord]
    }

    /// A nil URL is an in-memory journal for tests, never the user's archive.
    init(url: URL? = nil) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1, archive.records.allSatisfy(\.isValid),
                  Set(archive.records.map(\.id)).count == archive.records.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            records = archive.records
        } catch {
            readFailed = true
            errorMessage = L10n.t("Could not read forecast history. The original file has been preserved; no records will be overwritten.")
        }
    }

    @discardableResult
    func record(_ snapshots: [StockForecastRecord]) -> Int {
        var ids = Set(records.map(\.id))
        let new = snapshots.filter { $0.isValid && $0.actualClose == nil && ids.insert($0.id).inserted }
        guard !new.isEmpty else { return 0 }
        return persist(records + new) ? new.count : 0
    }

    /// One bounded, hourly-retried request per symbol/session, shared by capture cohorts.
    func reconcile(token: String, session: URLSession, now: Date = Date()) async {
        let pending = records.filter { $0.actualClose == nil && now >= $0.evaluationAfter }
        let groups = Dictionary(grouping: pending) { "\($0.stockID)|\($0.sessionStart.timeIntervalSince1970)" }
        var resolutions: [String: Decimal] = [:]
        var failed = false
        for key in groups.keys.sorted().filter({ now.timeIntervalSince(attempts[$0] ?? .distantPast) >= 3600 }).prefix(20) {
            guard let record = groups[key]?.first, let stock = record.stock else { continue }
            attempts[key] = now
            do {
                try Task.checkCancellation()
                let closes = try await TossInvestAPI.recordedClose(token: token, stock: stock,
                                                                   sessionEnd: record.sessionEnd, session: session)
                try Task.checkCancellation()
                let matching = closes.filter { record.marketCalendar.startOfDay(for: $0.date) == record.tradingDay }
                if matching.count == 1, let close = matching.first?.close,
                   close > 0, NSDecimalNumber(decimal: close).doubleValue.isFinite {
                    for item in groups[key] ?? [] { resolutions[item.id] = close }
                } else { failed = true }
                try await Task.sleep(for: .milliseconds(60))
            } catch is CancellationError { return }
            catch { failed = true }
        }
        guard !Task.isCancelled else { return }
        if !resolutions.isEmpty {
            let next = records.map { record in
                var resolved = record
                if resolved.actualClose == nil, let close = resolutions[record.id] {
                    resolved.actualClose = close
                    resolved.evaluatedAt = now
                }
                return resolved
            }
            _ = persist(next)
        }
        if failed {
            reconciliationMessage = L10n.t("Some daily closes are unavailable. Those predictions remain pending and will be retried.")
        } else if records.allSatisfy({ $0.actualClose != nil || now < $0.evaluationAfter }) {
            reconciliationMessage = nil
        }
    }

    private func persist(_ next: [StockForecastRecord]) -> Bool {
        guard !readFailed else { return false }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                // ponytail: a small daily journal; move encoding off-main if archive size makes writes noticeable.
                try encoder.encode(Archive(records: next)).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            records = next
            errorMessage = nil
            return true
        } catch {
            errorMessage = L10n.t("Could not save forecast history. Existing records are retained; check disk space and permissions.")
            return false
        }
    }

    static func csv(_ records: [StockForecastRecord]) -> String {
        let date = ISO8601DateFormatter()
        func text(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func number(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }
        let header = "symbol,name,currency,model,capture,predicted_at,quote_at,session_start,session_end,previous_close,input_price,expected_close,lower_80,upper_80,rise_probability,observations,actual_close,evaluated_at,direction_hit,absolute_percentage_error,brier_score,evidence_source,daily_log_return_volatility,completed_closes,history_adjusted"
        let rows = records.map { r in
            let closes = r.evidence.map { evidence in
                evidence.closes.map { "\(date.string(from: $0.date))=\(number($0.price))" }.joined(separator: ";")
            }
            var fields: [String] = [text(r.stockID), text(r.name), text(r.currency), text(r.model), text(r.capture.rawValue),
                date.string(from: r.createdAt), date.string(from: r.quoteAt), date.string(from: r.sessionStart),
                date.string(from: r.sessionEnd)]
            fields += [number(r.previousClose), number(r.inputPrice), number(r.expectedClose),
                       number(r.lowerClose), number(r.upperClose), String(r.riseProbability), String(r.observations)]
            fields += [number(r.actualClose), r.evaluatedAt.map { date.string(from: $0) } ?? "",
                       r.directionHit.map { $0 ? "1" : "0" } ?? "",
                       r.absolutePercentageError.map { String($0) } ?? "", r.brierScore.map { String($0) } ?? ""]
            fields += [r.evidence == nil ? "" : text("Toss Securities"),
                       r.evidence?.dailyVolatility.map { String($0) } ?? "", closes.map(text) ?? "",
                       r.evidence.map { $0.adjusted ? "true" : "false" } ?? ""]
            return fields.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
