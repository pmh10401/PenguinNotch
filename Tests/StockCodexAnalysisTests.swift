import Foundation
import XCTest
@testable import PenguinNotch

@MainActor
final class StockCodexAnalysisTests: XCTestCase {
    private let forecast = #"{"status":"forecast","expectedClose":104,"lowerClose":99,"upperClose":110,"riseProbability":0.8,"notes":"Daily history only."}"#
    private let abstention = #"{"status":"abstain","expectedClose":null,"lowerClose":null,"upperClose":null,"riseProbability":null,"notes":"Insufficient confidence."}"#
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var instant: Date { date("2026-09-25T19:00:00Z") }

    private func record(stockID: String = "us:AAPL", createdAt: Date? = nil, quoteAt: Date? = nil,
                        price: Decimal = 102, evidence supplied: StockForecastEvidence? = nil,
                        dayOffset: TimeInterval = 0) -> StockForecastRecord {
        let evidence = supplied ?? StockForecastEvidence(closes: (0..<21).map { index in
            .init(date: date("2026-09-24T04:00:00Z").addingTimeInterval(dayOffset - Double(index) * 86400),
                  price: index.isMultiple(of: 2) ? 100 : 102)
        })
        return StockForecastRecord(stockID: stockID, name: "DO_NOT_UPLOAD_NAME", currency: "USD",
            model: "DO_NOT_UPLOAD_SOURCE_MODEL", capture: .manual,
            createdAt: createdAt ?? instant.addingTimeInterval(dayOffset),
            quoteAt: quoteAt ?? instant.addingTimeInterval(dayOffset),
            sessionStart: date("2026-09-25T13:30:00Z").addingTimeInterval(dayOffset),
            sessionEnd: date("2026-09-25T20:00:00Z").addingTimeInterval(dayOffset),
            previousClose: 100, inputPrice: price, expectedClose: 999, lowerClose: 998, upperClose: 1000,
            riseProbability: 0.1, observations: evidence.closes.count - 1, evidence: evidence,
            actualClose: nil, evaluatedAt: nil)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "StockCodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertFailure(_ expected: StockCodexAnalysisError, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> StockCodexAnalysis) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StockCodexAnalysisError, expected, file: file, line: line)
        }
    }

    func testWhitelistFrozenInputResolvedModelAndSameInputGBMPair() async throws {
        var now = instant
        let source = record()
        let text = forecast
        let store = StockCodexAnalysisStore(clock: { now }) { prompt, schema in
            let schemaObject = try XCTUnwrap(JSONSerialization.jsonObject(with: schema) as? [String: Any])
            XCTAssertEqual(schemaObject["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(try XCTUnwrap(schemaObject["required"] as? [String])),
                           ["status", "expectedClose", "lowerClose", "upperClose", "riseProbability", "notes"])
            let json = try XCTUnwrap(prompt.components(separatedBy: "PUBLIC_INPUT_JSON:\n").last)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["stockID", "currency", "capturedAt", "quoteAt", "sessionStart", "sessionEnd", "previousClose", "inputPrice", "evidence"])
            for forbidden in [source.name, source.model, "expectedClose\":999", "accountSeq", "accountNo", "quantity", "clientSecret", "minutes"] {
                XCTAssertFalse(json.contains(forbidden), forbidden)
            }
            now = now.addingTimeInterval(30)
            return (text, "gpt-6-astra")
        }
        let analysis = try await store.analyze(input: source)
        XCTAssertEqual(analysis.model, "gpt-6-astra")
        XCTAssertEqual(analysis.promptVersion, 1)
        XCTAssertEqual(analysis.createdAt, instant)
        XCTAssertEqual(analysis.completedAt, instant.addingTimeInterval(30))
        XCTAssertEqual(analysis.input.evidence, source.evidence)
        XCTAssertEqual(analysis.input.quoteAt, source.quoteAt)
        let ai = try XCTUnwrap(analysis.forecastRecord)
        XCTAssertEqual(ai.createdAt, analysis.completedAt, "Never backdate model completion to quote capture")
        XCTAssertEqual(ai.expectedClose, 104)
        XCTAssertEqual(ai.model, "Codex gpt-6-astra prompt v1")
        let baseline = try XCTUnwrap(analysis.pairedGBMRecord)
        let expected = try XCTUnwrap(StockForecast.estimate(price: source.inputPrice,
            completedCloses: source.evidence!.closes.map(\.price),
            trading: TradingSession(startTime: source.sessionStart, endTime: source.sessionEnd), now: source.quoteAt))
        XCTAssertEqual(baseline.lowerClose, expected.lowerClose, "Variance uses frozen quote time, not response time")
        XCTAssertEqual(baseline.riseProbability, expected.riseProbability)
        XCTAssertEqual(ai.evidence, baseline.evidence)
        XCTAssertEqual(ai.quoteAt, baseline.quoteAt)
        XCTAssertEqual(ai.capture, .manual)
        XCTAssertTrue(ai.isValid && baseline.isValid)
        XCTAssertEqual(store.latest(stockID: source.stockID)?.id, analysis.id)
        XCTAssertNil(store.latest(stockID: "us:MSFT"))
        XCTAssertNil(store.loadingStockID)
        XCTAssertEqual(store.score.total, 1)
        XCTAssertEqual(store.score.evaluated, 0)
    }

    func testStrictResponseRejectsExtraMissingWrongTypeNonfiniteAndInvalidBounds() throws {
        XCTAssertEqual(try StockCodexAnalysisResponse.parse(forecast).expectedClose, 104)
        XCTAssertEqual(try StockCodexAnalysisResponse.parse(abstention).status, .abstain)
        let invalid = [
            forecast.replacingOccurrences(of: "\"notes\":", with: "\"accountSeq\":0,\"notes\":"),
            forecast.replacingOccurrences(of: ",\"notes\":\"Daily history only.\"", with: ""),
            forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":\"104\""),
            forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":true"),
            forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":0"),
            forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":null"),
            forecast.replacingOccurrences(of: "\"lowerClose\":99", with: "\"lowerClose\":105"),
            forecast.replacingOccurrences(of: "\"upperClose\":110", with: "\"upperClose\":103"),
            forecast.replacingOccurrences(of: "\"riseProbability\":0.8", with: "\"riseProbability\":1.01"),
            forecast.replacingOccurrences(of: "\"riseProbability\":0.8", with: "\"riseProbability\":-0.01"),
            forecast.replacingOccurrences(of: "\"riseProbability\":0.8", with: "\"riseProbability\":NaN"),
            forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":1e400"),
            forecast.replacingOccurrences(of: "Daily history only.", with: "  \n  "),
            forecast.replacingOccurrences(of: "Daily history only.", with: String(repeating: "a", count: 2001)),
            forecast.replacingOccurrences(of: "\"status\":\"forecast\"", with: "\"status\":\"abstain\""),
            abstention.replacingOccurrences(of: "\"expectedClose\":null", with: "\"expectedClose\":100"),
            "```json\n\(forecast)\n```", String(repeating: " ", count: 16_385) + forecast
        ]
        for (index, response) in invalid.enumerated() {
            XCTAssertThrowsError(try StockCodexAnalysisResponse.parse(response), "Case \(index)") {
                XCTAssertEqual($0 as? StockCodexAnalysisError, .invalidResponse)
            }
        }
    }

    func testFutureStaleAndClosedInputsNeverReachRunner() async {
        var calls = 0
        let text = forecast
        let now = instant
        let store = StockCodexAnalysisStore(clock: { now }) { _, _ in calls += 1; return (text, "gpt-6-astra") }
        await assertFailure(.expiredInput) {
            try await store.analyze(input: record(createdAt: now.addingTimeInterval(0.001), quoteAt: now.addingTimeInterval(0.001)))
        }
        await assertFailure(.expiredInput) {
            try await store.analyze(input: record(createdAt: now.addingTimeInterval(-120.001), quoteAt: now.addingTimeInterval(-120.001)))
        }
        let closed = StockCodexAnalysisStore(clock: { self.date("2026-09-25T20:00:00Z") }) { _, _ in calls += 1; return (text, "gpt-6-astra") }
        await assertFailure(.expiredInput) {
            try await closed.analyze(input: record(createdAt: date("2026-09-25T19:59:59Z"), quoteAt: date("2026-09-25T19:59:59Z")))
        }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.analyses.isEmpty)
        XCTAssertNil(store.loadingStockID)
    }

    func testResponseFreshnessBoundaryRegularCloseAndClockRollback() async throws {
        for elapsed in [120.0, 120.001, -0.001] {
            var now = instant
            let text = forecast
            let store = StockCodexAnalysisStore(clock: { now }) { _, _ in now = now.addingTimeInterval(elapsed); return (text, "gpt-6-astra") }
            if elapsed == 120 {
                let result = try await store.analyze(input: record())
                XCTAssertEqual(result.completedAt, now)
            } else {
                await assertFailure(.expiredInput) { try await store.analyze(input: record()) }
                XCTAssertTrue(store.records.isEmpty)
                XCTAssertNotNil(store.errorMessage)
            }
            XCTAssertNil(store.loadingStockID)
        }
        var now = date("2026-09-25T19:59:30Z")
        let source = record(createdAt: now, quoteAt: now)
        let text = abstention
        let store = StockCodexAnalysisStore(clock: { now }) { _, _ in now = now.addingTimeInterval(30); return (text, "gpt-6-astra") }
        await assertFailure(.expiredInput) { try await store.analyze(input: source) }
        XCTAssertTrue(store.analyses.isEmpty, "Even an abstention cannot save a result after regular close")
    }

    func testDailyEvidenceRequiredAndMustPrecedeTargetWithoutDuplicateDays() async throws {
        let source = record()
        var future = source.evidence!.closes
        future[0] = .init(date: date("2026-09-25T04:00:00Z"), price: 100)
        var duplicate = source.evidence!.closes
        duplicate[1] = .init(date: duplicate[0].date, price: 102)
        var missing = source
        // The journal allows legacy records without evidence; the AI upload never does.
        missing = StockForecastRecord(stockID: source.stockID, name: source.name, currency: source.currency,
            model: source.model, capture: source.capture, createdAt: source.createdAt, quoteAt: source.quoteAt,
            sessionStart: source.sessionStart, sessionEnd: source.sessionEnd, previousClose: source.previousClose,
            inputPrice: source.inputPrice, expectedClose: source.expectedClose, lowerClose: source.lowerClose,
            upperClose: source.upperClose, riseProbability: source.riseProbability, observations: source.observations,
            evidence: nil, actualClose: nil, evaluatedAt: nil)
        var calls = 0
        let text = forecast
        let store = StockCodexAnalysisStore(clock: { self.instant }) { _, _ in calls += 1; return (text, "gpt-6-astra") }
        for invalid in [missing, record(evidence: .init(closes: future)), record(evidence: .init(closes: duplicate)),
                        record(evidence: .init(closes: Array(future.prefix(20))))] {
            await assertFailure(.invalidInput) { try await store.analyze(input: invalid) }
        }
        XCTAssertEqual(calls, 0)
    }

    func testAbstentionRoundTripRetryDedupAndExistingGBMArchiveUntouched() async throws {
        let root = try folder()
        let legacyURL = root.appending(path: "history.json")
        let journal = StockForecastJournal(url: legacyURL)
        XCTAssertEqual(journal.record([record()]), 1)
        let original = try Data(contentsOf: legacyURL)
        let url = root.appending(path: "AIAnalyses/history.json")
        var output = abstention
        var calls = 0
        let store = StockCodexAnalysisStore(url: url, clock: { self.instant }) { _, _ in calls += 1; return (output, "gpt-6-astra") }
        _ = try await store.analyze(input: record())
        XCTAssertEqual(store.analyses.count, 1)
        XCTAssertEqual(store.score.total, 0)
        XCTAssertNil(store.analyses.first?.pairedGBMRecord)
        output = forecast
        let accepted = try await store.analyze(input: record())
        await assertFailure(.alreadyRecorded) { try await store.analyze(input: record()) }
        XCTAssertEqual(calls, 2, "A saved daily forecast must not trigger another upload or scored sample")
        let loaded = StockCodexAnalysisStore(url: url, runner: { _, _ in XCTFail("Load must not run a model"); return ("", "") })
        XCTAssertNil(loaded.errorMessage)
        XCTAssertEqual(loaded.analyses.count, 2)
        XCTAssertEqual(loaded.analyses.last?.id, accepted.id)
        XCTAssertEqual(loaded.analyses.last?.input, accepted.input)
        XCTAssertEqual(loaded.analyses.last?.response, accepted.response)
        XCTAssertEqual(loaded.analyses.first?.response.status, .abstain)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for forbidden in ["accountSeq", "accountNo", "quantity", "balance", "clientSecret", "DO_NOT_UPLOAD"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptUnknownVersionAndUnknownNestedFieldsNeverOverwriteArchive() async throws {
        let url = try folder().appending(path: "AIAnalyses/history.json")
        let text = forecast
        let store = StockCodexAnalysisStore(url: url, clock: { self.instant }) { _, _ in (text, "gpt-6-astra") }
        _ = try await store.analyze(input: record())
        let valid = try Data(contentsOf: url)
        var variants = [Data("{broken".utf8)]
        for kind in 0..<8 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var analyses = try XCTUnwrap(object["analyses"] as? [[String: Any]])
            switch kind {
            case 0: object["version"] = 2
            case 1: object["accountSeq"] = 7
            case 2: analyses[0]["promptVersion"] = 2
            case 3:
                var input = analyses[0]["input"] as! [String: Any]
                input["quantity"] = 1
                analyses[0]["input"] = input
            case 4:
                var response = analyses[0]["response"] as! [String: Any]
                response["expectedClose"] = 200
                analyses[0]["response"] = response
            case 5: analyses[0]["completedAt"] = instant.addingTimeInterval(121).timeIntervalSince1970
            case 6: analyses.append(analyses[0])
            default:
                analyses[0]["resolution"] = ["actualClose": 105, "evaluatedAt": instant.timeIntervalSince1970]
            }
            object["analyses"] = analyses
            variants.append(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
        }
        for (index, data) in variants.enumerated() {
            try data.write(to: url)
            var calls = 0
            let loaded = StockCodexAnalysisStore(url: url, clock: { self.instant }) { _, _ in calls += 1; return (text, "gpt-6-astra") }
            XCTAssertNotNil(loaded.errorMessage, "Corruption \(index)")
            await assertFailure(.archiveRead) { try await loaded.analyze(input: record()) }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testWriteFailureExternalChangeAndBadModelPreserveSavedRecords() async throws {
        let root = try folder()
        let url = root.appending(path: "AIAnalyses/history.json")
        var now = instant
        let text = forecast
        var model = "gpt-6-astra"
        let store = StockCodexAnalysisStore(url: url, clock: { now }) { _, _ in (text, model) }
        let saved = try await store.analyze(input: record())
        now = now.addingTimeInterval(86400 * 3)
        for invalidModel in ["", "gpt-6-astra\nsecret", String(repeating: "a", count: 65)] {
            model = invalidModel
            await assertFailure(.invalidResponse) { try await store.analyze(input: record(dayOffset: 86400 * 3)) }
            XCTAssertEqual(store.analyses.map(\.id), [saved.id])
        }
        model = "gpt-6-astra"
        let externallyChanged = Data("{\"version\":999,\"analyses\":[]}".utf8)
        try externallyChanged.write(to: url)
        await assertFailure(.archiveWrite) { try await store.analyze(input: record(dayOffset: 86400 * 3)) }
        XCTAssertEqual(store.analyses.map(\.id), [saved.id])
        XCTAssertEqual(try Data(contentsOf: url), externallyChanged)
        XCTAssertNotNil(store.errorMessage)
        let blocked = root.appending(path: "not-a-directory")
        try Data("blocker".utf8).write(to: blocked)
        let failing = StockCodexAnalysisStore(url: blocked.appending(path: "history.json"), clock: { self.instant }) { _, _ in (text, model) }
        await assertFailure(.archiveWrite) { try await failing.analyze(input: record()) }
        XCTAssertTrue(failing.analyses.isEmpty)
    }

    func testBusyCancellationAndRunnerFailureClearLoadingWithoutPersisting() async throws {
        let ready = expectation(description: "Runner started")
        var continuation: CheckedContinuation<(text: String, model: String), Never>?
        let store = StockCodexAnalysisStore(clock: { self.instant }) { _, _ in
            await withCheckedContinuation { continuation = $0; ready.fulfill() }
        }
        let task = Task { try await store.analyze(input: record()) }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(store.loadingStockID, "us:AAPL")
        await assertFailure(.busy) { try await store.analyze(input: record(stockID: "us:MSFT")) }
        task.cancel()
        continuation?.resume(returning: (forecast, "gpt-6-astra"))
        do { _ = try await task.value; XCTFail("Cancelled response must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.loadingStockID)
        XCTAssertTrue(store.analyses.isEmpty)
        let failing = StockCodexAnalysisStore(clock: { self.instant }) { _, _ in
            throw NSError(domain: "DO_NOT_DISPLAY_SECRET", code: 1, userInfo: [NSLocalizedDescriptionKey: "DO_NOT_DISPLAY_SECRET"])
        }
        await assertFailure(.runnerFailed) { try await failing.analyze(input: record()) }
        XCTAssertFalse(failing.errorMessage?.contains("DO_NOT_DISPLAY_SECRET") ?? true)
        XCTAssertNil(failing.loadingStockID)
        XCTAssertTrue(failing.analyses.isEmpty)
        for safeError in [StockCodexRunner.Failure.notInstalled, .loginNeeded, .timedOut] {
            let known = StockCodexAnalysisStore(clock: { self.instant }) { _, _ in throw safeError }
            do { _ = try await known.analyze(input: record()); XCTFail("Expected runner failure") }
            catch { XCTAssertEqual(error as? StockCodexRunner.Failure, safeError) }
            XCTAssertEqual(known.errorMessage, safeError.localizedDescription)
            XCTAssertNil(known.loadingStockID)
        }
    }

    func testStoreOwnedTaskCanCancelAndRestartWithoutSavingCancelledResult() async throws {
        let url = try folder().appending(path: "AIAnalyses/history.json")
        let firstStarted = expectation(description: "First runner starts")
        let cancelled = expectation(description: "Runner receives cancellation")
        let secondStarted = expectation(description: "Second runner starts")
        var calls = 0
        let text = forecast
        let store = StockCodexAnalysisStore(url: url, clock: { self.instant }) { _, _ in
            calls += 1
            if calls == 1 {
                firstStarted.fulfill()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { cancelled.fulfill(); throw error }
            } else { secondStarted.fulfill() }
            return (text, "gpt-6-astra")
        }
        store.startAnalysis(input: record())
        store.startAnalysis(input: record(stockID: "us:MSFT"))
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(calls, 1, "The wrapper prevents another task before loading is published")
        store.cancelAnalysis()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(store.analyses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.loadingStockID)
        store.startAnalysis(input: record())
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.loadingStockID)
    }

    func testExactTradingDayReconciliationAndScoreDenominatorsSurviveRestart() async throws {
        let url = try folder().appending(path: "AIAnalyses/history.json")
        var output = forecast
        let store = StockCodexAnalysisStore(url: url, clock: { self.instant }) { _, _ in (output, "gpt-6-astra") }
        for symbol in ["AAPL", "MSFT", "PENDING"] { _ = try await store.analyze(input: record(stockID: "us:\(symbol)")) }
        output = forecast.replacingOccurrences(of: "\"expectedClose\":104", with: "\"expectedClose\":100")
            .replacingOccurrences(of: "\"riseProbability\":0.8", with: "\"riseProbability\":0.5")
        _ = try await store.analyze(input: record(stockID: "us:TIE", price: 100))
        output = abstention
        _ = try await store.analyze(input: record(stockID: "us:ABSTAIN"))
        let before = store.analyses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexCloseEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        CodexCloseEndpoint.reset()
        await store.reconcile(token: "SYNTHETIC_TOKEN", session: session, now: date("2026-09-26T01:00:00Z"))
        XCTAssertTrue(CodexCloseEndpoint.requests.isEmpty, "New York trading day is still unfinished")
        await store.reconcile(token: "SYNTHETIC_TOKEN", session: session, now: date("2026-09-26T04:01:00Z"))
        XCTAssertEqual(CodexCloseEndpoint.requests.count, 4)
        XCTAssertEqual(store.score.evaluated, 0, "Only prior-day candles were returned")
        CodexCloseEndpoint.available = true
        await store.reconcile(token: "SYNTHETIC_TOKEN", session: session, now: date("2026-09-26T04:30:00Z"))
        XCTAssertEqual(CodexCloseEndpoint.requests.count, 4, "Retry is bounded to once per hour")
        await store.reconcile(token: "SYNTHETIC_TOKEN", session: session, now: date("2026-09-26T05:01:00Z"))
        XCTAssertEqual(CodexCloseEndpoint.requests.count, 8)
        XCTAssertEqual(store.score.total, 4)
        XCTAssertEqual(store.score.evaluated, 3)
        XCTAssertEqual(store.score.directionCount, 2)
        XCTAssertEqual(store.score.directionHits, 1)
        XCTAssertEqual(try XCTUnwrap(store.score.meanError), (1.0 / 105 + 5.0 / 99) * 100 / 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.score.baselineError), (3.0 / 105 + 3.0 / 99) * 100 / 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(store.score.brier), (0.04 + 0.64 + 0.25) / 3, accuracy: 1e-9)
        XCTAssertEqual(store.comparison.pairedCount, 3)
        for (initial, resolved) in zip(before, store.analyses) {
            XCTAssertEqual(initial.id, resolved.id)
            XCTAssertEqual(initial.input, resolved.input)
            XCTAssertEqual(initial.response, resolved.response)
            XCTAssertEqual(initial.completedAt, resolved.completedAt)
        }
        for request in CodexCloseEndpoint.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "adjusted" }?.value, "false")
            XCTAssertEqual(query.first { $0.name == "before" }?.value, "2026-09-25T20:00:00Z")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Tossinvest-Account"))
        }
        let loaded = StockCodexAnalysisStore(url: url, runner: { _, _ in XCTFail("Offline load"); return ("", "") })
        XCTAssertNil(loaded.errorMessage)
        XCTAssertEqual(loaded.score.evaluated, 3)
        XCTAssertEqual(loaded.comparison.pairedCount, 3)
        XCTAssertEqual(loaded.records.first?.actualClose, 105)
        XCTAssertNil(loaded.records.first { $0.stockID == "us:PENDING" }?.actualClose)
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(json.contains("SYNTHETIC_TOKEN"))
    }
}

private final class CodexCloseEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var saved: [URLRequest] = []
    private static var ready = false
    static var requests: [URLRequest] { lock.withLock { saved } }
    static var available: Bool {
        get { lock.withLock { ready } }
        set { lock.withLock { ready = newValue } }
    }
    static func reset() { lock.withLock { saved = []; ready = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let ready = Self.lock.withLock { Self.saved.append(request); return Self.ready }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        let symbol = query?.first { $0.name == "symbol" }?.value ?? ""
        let day = ready && symbol != "PENDING" ? "25" : "24"
        let price = symbol == "MSFT" ? 99 : symbol == "TIE" ? 100 : 105
        let data = Data("{\"result\":{\"candles\":[{\"timestamp\":\"2026-09-\(day)T00:00:00-04:00\",\"closePrice\":\"\(price)\"}]}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
