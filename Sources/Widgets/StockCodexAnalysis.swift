import Combine
import CoreFoundation
import Darwin
import Foundation

/// A manual analysis uses only this whitelist, never an encoded portfolio or preferences object.
struct StockCodexAnalysisInput: Codable, Equatable {
    let stockID: String
    let currency: String
    let capturedAt: Date
    let quoteAt: Date
    let sessionStart: Date
    let sessionEnd: Date
    let previousClose: Decimal
    let inputPrice: Decimal
    let evidence: StockForecastEvidence

    init(record: StockForecastRecord, now: Date) throws {
        guard record.isValid, record.actualClose == nil, record.evaluatedAt == nil,
              let evidence = record.evidence else { throw StockCodexAnalysisError.invalidInput }
        stockID = record.stockID
        currency = record.currency
        capturedAt = record.createdAt
        quoteAt = record.quoteAt
        sessionStart = record.sessionStart
        sessionEnd = record.sessionEnd
        previousClose = record.previousClose
        inputPrice = record.inputPrice
        self.evidence = evidence
        guard isValid else { throw StockCodexAnalysisError.invalidInput }
        guard isFresh(at: now) else { throw StockCodexAnalysisError.expiredInput }
    }

    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince1970.isFinite && capturedAt <= now
            && (0...120).contains(now.timeIntervalSince(quoteAt))
            && sessionStart <= now && now < sessionEnd
    }

    fileprivate var gbm: StockForecast? {
        StockForecast.estimate(price: inputPrice, completedCloses: evidence.closes.map(\.price),
            trading: TradingSession(startTime: sessionStart, endTime: sessionEnd), now: quoteAt)
    }

    fileprivate var isValid: Bool {
        guard [capturedAt, quoteAt, sessionStart, sessionEnd].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              (21...61).contains(evidence.closes.count),
              let gbm else { return false }
        return record(gbm, model: StockForecastRecord.modelVersion, createdAt: capturedAt).isValid
    }

    fileprivate func record(_ forecast: StockForecast, model: String, createdAt: Date,
                            resolution: StockCodexAnalysis.Resolution? = nil) -> StockForecastRecord {
        StockForecastRecord(stockID: stockID, name: WatchedStock.parse(stockID)?.symbol ?? stockID,
            currency: currency, model: model, capture: .manual, createdAt: createdAt, quoteAt: quoteAt,
            sessionStart: sessionStart, sessionEnd: sessionEnd, previousClose: previousClose,
            inputPrice: inputPrice, expectedClose: forecast.expectedClose, lowerClose: forecast.lowerClose,
            upperClose: forecast.upperClose, riseProbability: forecast.riseProbability,
            observations: evidence.closes.count - 1, evidence: evidence,
            actualClose: resolution?.actualClose, evaluatedAt: resolution?.evaluatedAt)
    }
}

struct StockCodexAnalysisResponse: Codable, Equatable {
    enum Status: String, Codable { case forecast, abstain }
    let status: Status
    let expectedClose: Decimal?
    let lowerClose: Decimal?
    let upperClose: Decimal?
    let riseProbability: Double?
    let notes: String

    private enum CodingKeys: String, CodingKey {
        case status, expectedClose, lowerClose, upperClose, riseProbability, notes
    }

    // Nulls are required, including in saved abstentions; omitted fields are not a valid response.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(expectedClose, forKey: .expectedClose)
        try container.encode(lowerClose, forKey: .lowerClose)
        try container.encode(upperClose, forKey: .upperClose)
        try container.encode(riseProbability, forKey: .riseProbability)
        try container.encode(notes, forKey: .notes)
    }

    static func parse(_ text: String) throws -> Self {
        do {
            let data = Data(text.utf8)
            guard data.count <= 16_384 else { throw StockCodexAnalysisError.invalidResponse }
            try validateJSON(JSONSerialization.jsonObject(with: data))
            let response = try JSONDecoder().decode(Self.self, from: data)
            guard response.isValid else { throw StockCodexAnalysisError.invalidResponse }
            return response
        } catch { throw StockCodexAnalysisError.invalidResponse }
    }

    fileprivate static func validateJSON(_ value: Any) throws {
        let object = try analysisObject(value, required: [
            "status", "expectedClose", "lowerClose", "upperClose", "riseProbability", "notes"
        ])
        for key in ["expectedClose", "lowerClose", "upperClose", "riseProbability"] {
            if object[key] is NSNull { continue }
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw StockCodexAnalysisError.invalidResponse
            }
        }
    }

    fileprivate var isValid: Bool {
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, notes.count <= 2_000 else { return false }
        if status == .abstain {
            return expectedClose == nil && lowerClose == nil && upperClose == nil && riseProbability == nil
        }
        guard let expectedClose, let lowerClose, let upperClose, let riseProbability else { return false }
        return [expectedClose, lowerClose, upperClose].allSatisfy {
            $0 > 0 && NSDecimalNumber(decimal: $0).doubleValue.isFinite
        } && lowerClose <= expectedClose && expectedClose <= upperClose
            && riseProbability.isFinite && (0...1).contains(riseProbability)
    }

    fileprivate func forecast(observations: Int) -> StockForecast? {
        guard status == .forecast, isValid, let expectedClose, let lowerClose,
              let upperClose, let riseProbability else { return nil }
        return StockForecast(riseProbability: riseProbability, expectedClose: expectedClose,
            observations: observations, lowerClose: lowerClose, upperClose: upperClose)
    }
}

/// Prediction, input and provenance never change. Only a subsequently observed close can be attached.
struct StockCodexAnalysis: Codable, Identifiable {
    static let promptVersion = 1
    static let outputSchema = #"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["forecast","abstain"]},"expectedClose":{"type":["number","null"],"exclusiveMinimum":0},"lowerClose":{"type":["number","null"],"exclusiveMinimum":0},"upperClose":{"type":["number","null"],"exclusiveMinimum":0},"riseProbability":{"type":["number","null"],"minimum":0,"maximum":1},"notes":{"type":"string","minLength":1,"maxLength":2000}},"required":["status","expectedClose","lowerClose","upperClose","riseProbability","notes"]}"#

    // Keep v1 text stable: the version plus canonical input reconstructs the exact submitted prompt.
    static func prompt(for input: StockCodexAnalysisInput) throws -> String {
        let json = String(decoding: try analysisEncoder().encode(input), as: UTF8.self)
        return """
        Estimate this stock's closing price for the supplied regular session, using only PUBLIC_INPUT_JSON.
        Do not use tools, files, news, outside prices or account information. Input times are Unix seconds.
        The evidence is adjusted, completed daily closes, newest first. The quote is the observed inputPrice.
        expectedClose is the expected regular close; lowerClose and upperClose bound a central 80% interval.
        riseProbability is P(regular close > previousClose), from 0 to 1. Require lowerClose <= expectedClose <= upperClose.
        Return only the schema's JSON object. Use status forecast with four finite numeric values, or abstain with all four null.
        Give a brief plain-text explanation in notes. Abstain when the supplied evidence does not support an estimate.
        PUBLIC_INPUT_JSON:
        \(json)
        """
    }

    struct Resolution: Codable {
        let actualClose: Decimal
        let evaluatedAt: Date
    }
    let id: UUID
    let input: StockCodexAnalysisInput
    let model: String
    let promptVersion: Int
    let createdAt: Date
    let completedAt: Date
    let response: StockCodexAnalysisResponse
    let resolution: Resolution?

    var forecastModel: String { "Codex \(model) prompt v\(promptVersion)" }

    var forecastRecord: StockForecastRecord? {
        response.forecast(observations: input.evidence.closes.count - 1).map {
            input.record($0, model: forecastModel, createdAt: completedAt, resolution: resolution)
        }
    }

    var pairedGBMRecord: StockForecastRecord? {
        guard response.status == .forecast, let gbm = input.gbm else { return nil }
        return input.record(gbm, model: StockForecastRecord.modelVersion,
                            createdAt: input.capturedAt, resolution: resolution)
    }

    fileprivate var isValid: Bool {
        guard Self.validModel(model), promptVersion == Self.promptVersion, input.isValid, response.isValid,
              input.isFresh(at: createdAt), input.isFresh(at: completedAt), createdAt <= completedAt else { return false }
        if response.status == .abstain { return resolution == nil }
        guard let forecastRecord, forecastRecord.isValid, pairedGBMRecord?.isValid == true else { return false }
        return resolution.map { $0.evaluatedAt.timeIntervalSince1970.isFinite } ?? true
    }

    fileprivate func resolved(close: Decimal, at now: Date) -> Self {
        Self(id: id, input: input, model: model, promptVersion: promptVersion,
             createdAt: createdAt, completedAt: completedAt, response: response,
             resolution: Resolution(actualClose: close, evaluatedAt: now))
    }

    fileprivate static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 64
            && model.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || [45, 46, 47, 58, 95].contains($0) }
    }
}

enum StockCodexAnalysisError: Error, LocalizedError, Equatable {
    case invalidInput, expiredInput, invalidResponse, busy, alreadyRecorded, runnerFailed, archiveRead, archiveWrite

    var errorDescription: String? {
        switch self {
        case .invalidInput: return L10n.t("Codex analysis requires a valid public quote and completed daily history.")
        case .expiredInput: return L10n.t("The quote expired or regular trading ended. Refresh before analyzing again.")
        case .invalidResponse: return L10n.t("Codex returned an invalid analysis. No prediction was saved.")
        case .busy: return L10n.t("A Codex analysis is already running.")
        case .alreadyRecorded: return L10n.t("A Codex prediction is already saved for this stock and trading day.")
        case .runnerFailed: return L10n.t("Codex analysis failed. No prediction was saved.")
        case .archiveRead: return L10n.t("Could not read Codex analyses. The original file is preserved and saving is disabled.")
        case .archiveWrite: return L10n.t("Could not save Codex analyses. Existing records are retained; check disk space and permissions.")
        }
    }
}

@MainActor
final class StockCodexAnalysisStore: ObservableObject {
    typealias Runner = (_ prompt: String, _ schema: Data) async throws -> (text: String, model: String)
    static let shared = StockCodexAnalysisStore(url: fileURL)
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PenguinNotch/Forecasts/AIAnalyses/history.json")
    }
    @Published private(set) var analyses: [StockCodexAnalysis] = []
    @Published private(set) var loadingStockID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var reconciliationMessage: String?
    var records: [StockForecastRecord] { analyses.compactMap(\.forecastRecord) }
    var score: StockForecastScore { StockForecastScore(records) }
    var comparison: StockForecastComparison {
        StockForecastComparison(analyses.flatMap { [$0.forecastRecord, $0.pairedGBMRecord].compactMap { $0 } })
    }

    private let url: URL?
    private let clock: () -> Date
    private let runner: Runner
    private var readFailed = false
    private var diskData: Data?
    private var attempts: [String: Date] = [:]
    private var reconciling = false
    private var analysisTask: Task<Void, Never>?
    private struct Archive: Codable {
        let version: Int
        let analyses: [StockCodexAnalysis]
    }

    /// Nil storage and an injected runner/clock keep tests entirely offline.
    init(url: URL? = nil, clock: @escaping () -> Date = Date.init, runner: @escaping Runner = { prompt, schema in
        let output = try await StockCodexRunner.run(prompt: prompt, schema: schema)
        return (output.text, output.model)
    }) {
        self.url = url
        self.clock = clock
        self.runner = runner
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let object = try analysisObject(JSONSerialization.jsonObject(with: data), required: ["version", "analyses"])
            guard let items = object["analyses"] as? [Any] else { throw StockCodexAnalysisError.archiveRead }
            for item in items { try Self.validateArchiveItem(item) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let archive = try decoder.decode(Archive.self, from: data)
            let ids = archive.analyses.compactMap { $0.forecastRecord?.id }
            guard archive.version == 1, archive.analyses.allSatisfy(\.isValid),
                  Set(archive.analyses.map(\.id)).count == archive.analyses.count,
                  Set(ids).count == ids.count else { throw StockCodexAnalysisError.archiveRead }
            analyses = archive.analyses
            diskData = data
        } catch {
            readFailed = true
            errorMessage = StockCodexAnalysisError.archiveRead.localizedDescription
        }
    }

    func latest(stockID: String) -> StockCodexAnalysis? {
        analyses.last { $0.input.stockID == stockID }
    }

    /// The task belongs to the store so dismissing a hover cannot lose its cancellation handle.
    func startAnalysis(input: StockForecastRecord) {
        guard analysisTask == nil, loadingStockID == nil else { return }
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisTask = nil }
            do { try await self.analyze(input: input) }
            catch { /* analyze exposes only safe, localized errors. Cancellation needs no alert. */ }
        }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    @discardableResult
    func analyze(input record: StockForecastRecord) async throws -> StockCodexAnalysis {
        guard loadingStockID == nil else { throw StockCodexAnalysisError.busy }
        do {
            try Task.checkCancellation()
            guard !readFailed else { throw StockCodexAnalysisError.archiveRead }
            let createdAt = clock()
            let input = try StockCodexAnalysisInput(record: record, now: createdAt)
            guard !records.contains(where: { $0.stockID == input.stockID && $0.sessionStart == input.sessionStart }) else {
                throw StockCodexAnalysisError.alreadyRecorded
            }
            loadingStockID = input.stockID
            defer { loadingStockID = nil }
            let output: (text: String, model: String)
            do { output = try await runner(StockCodexAnalysis.prompt(for: input), Data(StockCodexAnalysis.outputSchema.utf8)) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as StockCodexRunner.Failure { throw failure }
            catch { throw StockCodexAnalysisError.runnerFailed }
            try Task.checkCancellation()
            let completedAt = clock()
            guard createdAt <= completedAt, input.isFresh(at: completedAt) else { throw StockCodexAnalysisError.expiredInput }
            guard StockCodexAnalysis.validModel(output.model) else { throw StockCodexAnalysisError.invalidResponse }
            let response = try StockCodexAnalysisResponse.parse(output.text)
            let analysis = StockCodexAnalysis(id: UUID(), input: input, model: output.model,
                promptVersion: StockCodexAnalysis.promptVersion, createdAt: createdAt, completedAt: completedAt,
                response: response, resolution: nil)
            guard analysis.isValid else { throw StockCodexAnalysisError.invalidResponse }
            try persist(analyses + [analysis])
            return analysis
        } catch is CancellationError { throw CancellationError() }
        catch let failure as StockCodexRunner.Failure {
            // Only the runner's fixed messages are safe; never surface stderr or arbitrary thrown text.
            errorMessage = failure.localizedDescription
            throw failure
        }
        catch {
            let failure = (error as? StockCodexAnalysisError) ?? .runnerFailed
            errorMessage = failure.localizedDescription
            throw failure
        }
    }

    /// Explicit public close lookup; the token is used only for this request and is never archived.
    func reconcile(token: String, session: URLSession, now: Date = Date()) async {
        guard !readFailed, !reconciling, now.timeIntervalSince1970.isFinite else { return }
        reconciling = true
        defer { reconciling = false }
        let pending = analyses.filter { $0.forecastRecord.map { $0.actualClose == nil && now >= $0.evaluationAfter } == true }
        var resolutions: [UUID: Decimal] = [:]
        var failed = false
        for analysis in pending.filter({ now.timeIntervalSince(attempts[$0.id.uuidString] ?? .distantPast) >= 3600 }).prefix(20) {
            guard let record = analysis.forecastRecord, let stock = record.stock else { continue }
            attempts[analysis.id.uuidString] = now
            do {
                try Task.checkCancellation()
                let closes = try await TossInvestAPI.recordedClose(token: token, stock: stock, sessionEnd: record.sessionEnd, session: session)
                try Task.checkCancellation()
                let matching = closes.filter { record.marketCalendar.startOfDay(for: $0.date) == record.tradingDay }
                if matching.count == 1, let close = matching.first?.close,
                   close > 0, NSDecimalNumber(decimal: close).doubleValue.isFinite {
                    resolutions[analysis.id] = close
                } else { failed = true }
                try await Task.sleep(for: .milliseconds(60))
            } catch is CancellationError { return }
            catch { failed = true }
        }
        guard !Task.isCancelled else { return }
        if !resolutions.isEmpty {
            do {
                try persist(analyses.map { analysis in
                    guard analysis.resolution == nil, let close = resolutions[analysis.id] else { return analysis }
                    return analysis.resolved(close: close, at: now)
                })
            } catch { errorMessage = StockCodexAnalysisError.archiveWrite.localizedDescription }
        }
        if failed {
            reconciliationMessage = L10n.t("Some daily closes are unavailable. Those predictions remain pending and will be retried.")
        } else if records.allSatisfy({ $0.actualClose != nil || now < $0.evaluationAfter }) {
            reconciliationMessage = nil
        }
    }

    private func persist(_ next: [StockCodexAnalysis]) throws {
        guard !readFailed else { throw StockCodexAnalysisError.archiveRead }
        do {
            if let url {
                // Refuse to replace another writer's data or newly corrupted/unknown-version data.
                let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                guard current == diskData else { throw StockCodexAnalysisError.archiveWrite }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try analysisEncoder().encode(Archive(version: 1, analyses: next))
                let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try data.write(to: temporary, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                // Set permissions before the atomic replacement: a permission error must preserve the old file.
                guard rename(temporary.path, url.path) == 0 else { throw StockCodexAnalysisError.archiveWrite }
                diskData = data
            }
            analyses = next
            errorMessage = nil
        } catch { throw StockCodexAnalysisError.archiveWrite }
    }

    private static func validateArchiveItem(_ value: Any) throws {
        let item = try analysisObject(value, required: ["id", "input", "model", "promptVersion", "createdAt", "completedAt", "response"], optional: ["resolution"])
        let input = try analysisObject(item["input"] as Any, required: ["stockID", "currency", "capturedAt", "quoteAt", "sessionStart", "sessionEnd", "previousClose", "inputPrice", "evidence"])
        let evidence = try analysisObject(input["evidence"] as Any, required: ["closes", "adjusted"])
        guard let closes = evidence["closes"] as? [Any] else { throw StockCodexAnalysisError.archiveRead }
        for close in closes { _ = try analysisObject(close, required: ["date", "price"]) }
        try StockCodexAnalysisResponse.validateJSON(item["response"] as Any)
        if let resolution = item["resolution"], !(resolution is NSNull) {
            _ = try analysisObject(resolution, required: ["actualClose", "evaluatedAt"])
        }
    }
}

private func analysisEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func analysisObject(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
    guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
          Set(object.keys).isSubset(of: required.union(optional)) else { throw StockCodexAnalysisError.invalidResponse }
    return object
}
