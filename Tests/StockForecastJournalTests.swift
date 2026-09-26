import Foundation
import XCTest
import SwiftUI
@testable import PenguinNotch

@MainActor
final class StockForecastJournalTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func record(capture: ForecastCapture = .scheduled, price: Decimal = 102,
                        expected: Decimal = 104, previous: Decimal = 100, probability: Double = 0.8,
                        actual: Decimal? = nil, name: String = "Example, Inc.",
                        createdAt: String = "2026-09-25T19:00:00Z",
                        quoteAt: String = "2026-09-25T19:00:00Z",
                        model: String = StockForecastRecord.modelVersion,
                        evidence: StockForecastEvidence? = nil) -> StockForecastRecord {
        StockForecastRecord(stockID: "us:TEST", name: name, currency: "USD",
            model: model, capture: capture, createdAt: date(createdAt),
            quoteAt: date(quoteAt), sessionStart: date("2026-09-25T13:30:00Z"),
            sessionEnd: date("2026-09-25T20:00:00Z"), previousClose: previous, inputPrice: price,
            expectedClose: expected, lowerClose: 100, upperClose: 106, riseProbability: probability,
            observations: 60, evidence: evidence, actualClose: actual,
            evaluatedAt: actual == nil ? nil : date("2026-09-26T04:01:00Z"))
    }

    private var evidence: StockForecastEvidence {
        StockForecastEvidence(closes: (0..<61).map { index in
            .init(date: date("2026-09-24T04:00:00Z").addingTimeInterval(-Double(index) * 86400),
                  price: index.isMultiple(of: 2) ? 100 : 101)
        })
    }

    func testEvidenceRoundTripsAndLegacyRecordsRemainReadableWithoutInventedInputs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "history.json")
        let journal = StockForecastJournal(url: file)
        XCTAssertEqual(journal.record([record(evidence: evidence), record(capture: .manual)]), 2)
        let loaded = StockForecastJournal(url: file)
        XCTAssertEqual(loaded.records.first?.evidence, evidence)
        XCTAssertEqual(loaded.records.first?.evidence?.adjusted, true)
        XCTAssertNil(loaded.records.last?.evidence)
        XCTAssertNotNil(evidence.dailyVolatility)
        XCTAssertEqual(try XCTUnwrap(evidence.historicalReturn(sessions: 5)), 100.0 / 101 - 1, accuracy: 1e-10)
        XCTAssertEqual(evidence.historicalReturn(sessions: 20), 0)
        XCTAssertNil(evidence.historicalReturn(sessions: 61))
        let csv = StockForecastJournal.csv(loaded.records)
        XCTAssertTrue(csv.contains("daily_log_return_volatility,completed_closes"))
        XCTAssertTrue(csv.contains("2026-09-24T04:00:00Z=100;"))
    }

    func testEvidenceRejectsFutureCandlesDuplicateDaysAndMismatchedPreviousClose() {
        XCTAssertTrue(record(evidence: evidence).isValid)
        var closes = evidence.closes
        closes[0] = .init(date: date("2026-09-25T04:00:00Z"), price: 100)
        XCTAssertFalse(record(evidence: .init(closes: closes)).isValid)
        closes = evidence.closes
        closes[1] = .init(date: closes[0].date, price: 101)
        XCTAssertFalse(record(evidence: .init(closes: closes)).isValid)
        XCTAssertFalse(record(previous: 99, evidence: evidence).isValid)
        XCTAssertFalse(record(evidence: .init(closes: Array(evidence.closes.dropLast()))).isValid)
    }

    func testModelComparisonUsesIdenticalInputsAndTargetsIncludingHistory() throws {
        let a = record(actual: 105, evidence: evidence)
        let b = record(expected: 103, actual: 105, createdAt: "2026-09-25T19:01:00Z",
                       model: "Test model v1", evidence: evidence)
        let comparison = StockForecastComparison([a, b])
        XCTAssertEqual(comparison.pairedCount, 1)
        XCTAssertEqual(comparison.rows.count, 2)
        XCTAssertTrue(comparison.rows.allSatisfy { $0.paired.evaluated == 1 })
        XCTAssertEqual(try XCTUnwrap(comparison.baselineError), 3.0 / 105 * 100, accuracy: 1e-10)
        for mismatch in [
            record(actual: 105, quoteAt: "2026-09-25T18:59:59Z", model: "Test model v1", evidence: evidence),
            record(price: 103, actual: 105, model: "Test model v1", evidence: evidence),
            record(capture: .manual, actual: 105, model: "Test model v1", evidence: evidence),
            record(actual: 106, model: "Test model v1", evidence: evidence),
            record(model: "Test model v1", evidence: evidence),
            record(actual: 105, model: "Test model v1")
        ] {
            XCTAssertEqual(StockForecastComparison([a, mismatch]).pairedCount, 0)
        }
        var closes = evidence.closes
        closes[1] = .init(date: closes[1].date, price: 102)
        XCTAssertEqual(StockForecastComparison([a, record(actual: 105, model: "Test model v1",
            evidence: .init(closes: closes))]).pairedCount, 0)
        XCTAssertEqual(StockForecastComparison([a, a, b]).pairedCount, 0, "Ambiguous duplicates cannot be paired")
        XCTAssertEqual(StockForecastComparison([record(actual: 105)]).pairedCount, 1,
                       "Legacy inputs still support their own price-hold baseline")
        XCTAssertTrue(StockForecastComparison([]).rows.isEmpty)
    }

    func testCalibrationBoundariesPendingAndTiesWithWilsonIntervals() throws {
        let bins = StockForecastCalibration.bins([
            record(probability: 0, actual: 99), record(probability: 0.1, actual: 105),
            record(probability: 0.5, actual: 100), record(probability: 1, actual: 105),
            record(probability: 0.8), record(probability: .nan, actual: 105),
            record(probability: -0.1, actual: 105)
        ])
        XCTAssertEqual(bins.map(\.id), [0, 1, 5, 9])
        XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, 4)
        XCTAssertEqual(bins[2].rises, 0, "Unchanged closes count as not rising even at 50%")
        XCTAssertEqual(bins[1].meanProbability, 0.1)
        XCTAssertEqual(bins[0].interval.lowerBound, 0, accuracy: 1e-10)
        XCTAssertEqual(bins[0].interval.upperBound, 0.7934506856, accuracy: 1e-9)
        XCTAssertEqual(bins[3].interval.lowerBound, 0.2065493144, accuracy: 1e-9)
        XCTAssertEqual(bins[3].interval.upperBound, 1, accuracy: 1e-10)
        XCTAssertTrue(StockForecastCalibration.bins([record()]).isEmpty)
    }

    func testEvidenceComparisonAndCalibrationRenderInEnglishAndKorean() throws {
        let previousLocale = L10n.testLocale
        defer { L10n.testLocale = previousLocale }
        let sample = record(expected: 102, actual: 105, evidence: evidence)
        for language in ["en", "ko"] {
            L10n.testLocale = Locale(identifier: language)
            let views: [(String, AnyView)] = [
                ("evidence", AnyView(ForecastEvidenceView(record: sample))),
                ("comparison", AnyView(ForecastComparisonView(records: [sample]))),
                ("calibration", AnyView(ForecastCalibrationView(records: [sample])))
            ]
            for (name, view) in views {
                let renderer = ImageRenderer(content: view.padding(20).frame(width: 800)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size.width, 800)
                XCTAssertGreaterThan(image.size.height, 100)
                let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                    .representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "forecast-\(name)-\(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let directory = ProcessInfo.processInfo.environment["FORECAST_RENDER_PATH"] {
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try png.write(to: folder.appending(path: "\(name)-\(language).png"))
                }
            }
        }
    }

    func testImmutableDailyCohortsPersistAndCorruptionIsNeverOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "history.json")
        let journal = StockForecastJournal(url: file)
        XCTAssertEqual(journal.record([record()]), 1)
        XCTAssertEqual(journal.record([record(expected: 999)]), 0)
        XCTAssertEqual(journal.records[0].expectedClose, 104)
        XCTAssertEqual(journal.record([record(capture: .manual)]), 1)
        let loaded = StockForecastJournal(url: file)
        XCTAssertEqual(loaded.records.count, 2)
        XCTAssertEqual(loaded.records[0].expectedClose, 104)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for forbidden in ["accountNo", "accountSeq", "quantity", "balance", "clientSecret"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        let broken = Data("{not an archive}".utf8)
        try broken.write(to: file)
        let corrupt = StockForecastJournal(url: file)
        XCTAssertNotNil(corrupt.errorMessage)
        XCTAssertEqual(corrupt.record([record()]), 0)
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testRecordingRejectsStaleAfterCloseAndWrongAutomaticHorizon() {
        let journal = StockForecastJournal()
        XCTAssertEqual(journal.record([
            record(createdAt: "2026-09-25T18:59:59Z", quoteAt: "2026-09-25T18:59:59Z"),
            record(createdAt: "2026-09-25T19:05:01Z", quoteAt: "2026-09-25T19:05:01Z"),
            record(quoteAt: "2026-09-25T18:57:59Z"),
            record(capture: .manual, createdAt: "2026-09-25T20:00:00Z", quoteAt: "2026-09-25T20:00:00Z"),
            record(quoteAt: "2026-09-25T19:00:01Z")
        ]), 0)
        XCTAssertEqual(journal.record([record(createdAt: "2026-09-25T19:05:00Z", quoteAt: "2026-09-25T19:05:00Z")]), 1)
        XCTAssertEqual(journal.record([record(capture: .manual, createdAt: "2026-09-25T18:00:00Z", quoteAt: "2026-09-25T18:00:00Z")]), 1)
    }

    func testScoresSeparatePriceDirectionRangeAndProbabilityWithHonestDenominators() throws {
        let score = StockForecastScore([
            record(actual: 105), record(actual: 99),
            record(price: 100, expected: 100, probability: 0.5, actual: 100), record()
        ])
        XCTAssertEqual(score.total, 4)
        XCTAssertEqual(score.evaluated, 3)
        XCTAssertEqual(score.directionHits, 1)
        XCTAssertEqual(score.directionCount, 2)
        XCTAssertEqual(try XCTUnwrap(score.meanError), (1.0 / 105 + 5.0 / 99) * 100 / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(score.baselineError), (3.0 / 105 + 3.0 / 99) * 100 / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(score.rangeCoverage), 200.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(score.brier), (0.04 + 0.64 + 0.25) / 3, accuracy: 0.00001)
        XCTAssertNil(StockForecastScore([]).meanError)
        XCTAssertEqual(StockForecastScore([]).directionCount, 0)
    }

    func testSettlementWaitsForLocalDateMatchesExactDayAndReusesAcrossCohorts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JournalEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        JournalEndpoint.reset()
        let journal = StockForecastJournal()
        journal.record([record(), record(capture: .manual)])
        // UTC is already Saturday, but New York is still Friday: its daily bar is not scored.
        await journal.reconcile(token: "fake", session: session, now: date("2026-09-26T01:00:00Z"))
        XCTAssertTrue(JournalEndpoint.requests.isEmpty)
        XCTAssertNil(journal.records[0].actualClose)
        // The API initially returns only the prior day. Never use it as today's actual close.
        await journal.reconcile(token: "fake", session: session, now: date("2026-09-26T04:01:00Z"))
        XCTAssertEqual(JournalEndpoint.requests.count, 1)
        XCTAssertNil(journal.records[0].actualClose)
        JournalEndpoint.targetAvailable = true
        await journal.reconcile(token: "fake", session: session, now: date("2026-09-26T04:30:00Z"))
        XCTAssertEqual(JournalEndpoint.requests.count, 1)
        await journal.reconcile(token: "fake", session: session, now: date("2026-09-26T05:01:00Z"))
        XCTAssertEqual(JournalEndpoint.requests.count, 2)
        XCTAssertTrue(journal.records.allSatisfy { $0.actualClose == 105 })
        XCTAssertNil(journal.reconciliationMessage)
        let request = try XCTUnwrap(JournalEndpoint.requests.first)
        let items = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "adjusted" }?.value, "false")
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "2026-09-25T20:00:00Z")
        XCTAssertEqual(items.first { $0.name == "count" }?.value, "2")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Tossinvest-Account"))
        await journal.reconcile(token: "fake", session: session, now: date("2026-09-26T06:02:00Z"))
        XCTAssertEqual(JournalEndpoint.requests.count, 2)
    }

    func testCSVPreservesNamesEscapesFormulaPrefixesAndKeepsPendingEmpty() {
        let csv = StockForecastJournal.csv([record(name: " =HYPERLINK(\"bad\")\n삼성전자")])
        XCTAssertTrue(csv.contains("\"' =HYPERLINK(\"\"bad\"\")\n삼성전자\""))
        XCTAssertTrue(csv.contains("actual_close,evaluated_at,direction_hit"))
        XCTAssertTrue(csv.hasSuffix(",,,,,,,,,\r\n"))
        XCTAssertFalse(csv.contains("account"))
    }
}

private final class JournalEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var available = false
    static var targetAvailable: Bool {
        get { lock.withLock { available } }
        set { lock.withLock { available = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; available = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let ready = Self.lock.withLock { Self.recorded.append(request); return Self.available }
        let day = ready ? "25" : "24"
        let body = Data("{\"result\":{\"candles\":[{\"timestamp\":\"2026-09-\(day)T00:00:00-04:00\",\"closePrice\":\"105\"}]}}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
