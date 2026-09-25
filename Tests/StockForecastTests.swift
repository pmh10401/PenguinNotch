import Foundation
import XCTest
@testable import PenguinNotch

final class StockForecastTests: XCTestCase {
    func testZeroDriftModelNeedsLiveSessionAndEnoughVariableHistory() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trading = TradingSession(startTime: start, endTime: start.addingTimeInterval(3600))
        let closes = (0..<61).map { Decimal($0.isMultiple(of: 2) ? 100 : 101) }
        let midpoint = start.addingTimeInterval(1800)
        let flat = try XCTUnwrap(StockForecast.estimate(price: 100, completedCloses: closes,
                                                         trading: trading, now: midpoint))
        XCTAssertEqual(flat.expectedClose, 100)
        XCTAssertEqual(flat.observations, 60)
        XCTAssertTrue((0.45...0.55).contains(flat.riseProbability))
        let higher = try XCTUnwrap(StockForecast.estimate(price: 102, completedCloses: closes,
                                                           trading: trading, now: midpoint))
        XCTAssertGreaterThan(higher.riseProbability, flat.riseProbability)
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: Array(closes.prefix(20)),
                                             trading: trading, now: midpoint))
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: closes,
                                             trading: trading, now: trading.endTime))
        XCTAssertNil(StockForecast.estimate(price: 100, completedCloses: Array(repeating: 100, count: 30),
                                             trading: trading, now: midpoint))
    }

    @MainActor
    func testActualAccountHoldingsProduceEstimatesWithoutPersistingPositions() async throws {
        let name = "Forecast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.stockQuoteSource = .toss
        preferences.portfolioForecastEnabled = true
        let store = StockForecastStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ForecastEndpoint.reset()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z"))

        let credentials = (clientID: "forecast-\(UUID().uuidString)", clientSecret: "fake-secret")
        await store.refresh(preferences: preferences, session: session, now: now,
                            credentials: credentials)

        XCTAssertNil(store.message)
        XCTAssertEqual(preferences.tossAccountSeq, 7)
        XCTAssertEqual(store.accounts.first?.maskedNumber, "•••• 8901")
        XCTAssertEqual(store.holdings.map(\.id), ["KR:005930"])
        XCTAssertNotNil(store.forecasts["KR:005930"])
        XCTAssertEqual(store.forecasts["KR:005930"]?.expectedClose, 100)
        XCTAssertNil(defaults.object(forKey: "holdings"))
        XCTAssertEqual(defaults.integer(forKey: "tossAccountSeq"), 7)
        let requests = ForecastEndpoint.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/api/v1/holdings" })?
            .value(forHTTPHeaderField: "X-Tossinvest-Account"), "7")
        XCTAssertTrue(requests.filter { $0.url?.path != "/api/v1/holdings" }
            .allSatisfy { $0.value(forHTTPHeaderField: "X-Tossinvest-Account") == nil })
        XCTAssertTrue(requests.filter { $0.url?.path != "/oauth2/token" }
            .allSatisfy { $0.httpMethod == "GET" })

        await store.refresh(preferences: preferences, session: session, now: now.addingTimeInterval(60),
                            credentials: credentials)
        // A second refresh reuses the in-memory history and stays below account limits.
        XCTAssertEqual(ForecastEndpoint.requests.filter { $0.url?.path == "/api/v1/holdings" }.count, 1)
        XCTAssertEqual(ForecastEndpoint.requests.filter { $0.url?.path == "/api/v1/candles" }.count, 1)

        preferences.portfolioForecastEnabled = false
        store.clear()
        XCTAssertTrue(store.holdings.isEmpty)
        XCTAssertTrue(store.forecasts.isEmpty)
    }

    func testMissingQuoteTimestampCannotBecomeAForecastInput() {
        let body = Data(#"{"result":[{"symbol":"005930","lastPrice":"100","currency":"KRW","timestamp":null}]}"#.utf8)
        XCTAssertNotNil(StockQuoteCodec.prices(from: body)["kr:005930"])
        XCTAssertNil(StockQuoteCodec.prices(from: body, requireTimestamp: true)["kr:005930"])
    }

    func testUSRegularSessionContinuesPastKoreanMidnight() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForecastEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let formatter = ISO8601DateFormatter()
        let overnight = try XCTUnwrap(formatter.date(from: "2026-09-25T17:00:00Z"))
        let closed = try XCTUnwrap(formatter.date(from: "2026-09-26T01:00:00Z"))

        let activeSession = try await TossInvestAPI.regularSession(token: "test", market: .us,
                                                                   at: overnight, session: session)
        let closedSession = try await TossInvestAPI.regularSession(token: "test", market: .us,
                                                                   at: closed, session: session)
        XCTAssertNotNil(activeSession)
        XCTAssertNil(closedSession)
    }
}

private final class ForecastEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let body: Data
        switch request.url?.path {
        case "/oauth2/token":
            body = Data(#"{"access_token":"forecast-test-token","expires_in":3600}"#.utf8)
        case "/api/v1/accounts":
            body = Data(#"{"result":[{"accountNo":"12345678901","accountSeq":7,"accountType":"BROKERAGE"}]}"#.utf8)
        case "/api/v1/holdings":
            body = Data(#"{"result":{"items":[{"symbol":"005930","name":"삼성전자","marketCountry":"KR","currency":"KRW"}]}}"#.utf8)
        case "/api/v1/market-calendar/KR":
            body = Data(#"{"result":{"today":{"integrated":{"regularMarket":{"startTime":"2026-09-25T09:00:00+09:00","endTime":"2026-09-25T15:30:00+09:00"}}},"previousBusinessDay":{"integrated":null}}}"#.utf8)
        case "/api/v1/market-calendar/US":
            body = Data(#"{"result":{"today":{"regularMarket":null},"previousBusinessDay":{"regularMarket":{"startTime":"2026-09-25T22:30:00+09:00","endTime":"2026-09-26T05:00:00+09:00"}}}}"#.utf8)
        case "/api/v1/prices":
            body = Data(#"{"result":[{"symbol":"005930","lastPrice":"100","currency":"KRW","timestamp":"2026-09-25T10:00:00+09:00"}]}"#.utf8)
        case "/api/v1/candles":
            let formatter = ISO8601DateFormatter()
            let base = formatter.date(from: "2026-09-24T00:00:00Z")!
            let candles: [[String: String]] = (0..<30).map { index in
                ["timestamp": formatter.string(from: base.addingTimeInterval(Double(-index * 86_400))),
                 "closePrice": index.isMultiple(of: 2) ? "100" : "101"]
            }
            body = try! JSONSerialization.data(withJSONObject: ["result": ["candles": candles]])
        default:
            XCTFail("Unexpected forecast request: \(request.url?.path ?? "nil")")
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
