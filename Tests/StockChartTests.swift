import XCTest
@testable import PenguinNotch

final class StockChartTests: XCTestCase {
    func testPriceAxisZoomsToVisibleCandleRange() {
        let candles = [
            StockCandle(end: .now, open: 100, high: 101.5, low: 99.5, close: 101, volume: 1),
            StockCandle(end: .now, open: 101, high: 102, low: 100.5, close: 101.5, volume: 1)
        ]

        let domain = StockChartSection.priceDomain(for: candles)
        XCTAssertGreaterThan(domain.lowerBound, 90)
        XCTAssertLessThan(domain.lowerBound, 99.5)
        XCTAssertGreaterThan(domain.upperBound, 102)
        XCTAssertLessThan(domain.upperBound, 110)
    }

    func testTenMinuteCandlesUseMinuteEndsAndAggregateOHLCV() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-25T09:00:00Z"))
        let minutes = [
            StockCandle(end: start.addingTimeInterval(60), open: 100, high: 103, low: 99,
                        close: 102, volume: 2),
            StockCandle(end: start.addingTimeInterval(600), open: 102, high: 104, low: 98,
                        close: 99, volume: 3),
            StockCandle(end: start.addingTimeInterval(660), open: 99, high: 101, low: 97,
                        close: 100, volume: 4)
        ]
        let candles = StockQuoteCodec.tenMinuteCandles(from: [minutes[2], minutes[1], minutes[0]])
        XCTAssertEqual(candles.count, 2)
        XCTAssertEqual(candles[0].end, start.addingTimeInterval(600))
        XCTAssertEqual(candles[0].open, 100)
        XCTAssertEqual(candles[0].high, 104)
        XCTAssertEqual(candles[0].low, 98)
        XCTAssertEqual(candles[0].close, 99)
        XCTAssertEqual(candles[0].volume, 5)
        XCTAssertEqual(candles[1].end, start.addingTimeInterval(1200))
        XCTAssertEqual(candles[1].open, 99)
    }

    func testChartFetchRequestsOnlySelectedSource() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartCandlesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ChartCandlesEndpoint.reset()

        let stock = WatchedStock(symbol: "005930", market: .kr)
        let minutes = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                           interval: .minute, session: session)
        XCTAssertEqual(minutes.count, 200)
        XCTAssertEqual(ChartCandlesEndpoint.requests.count, 1)
        XCTAssertEqual(StockQuoteCodec.tenMinuteCandles(from: minutes).count, 20)

        let days = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                        interval: .day, session: session)
        XCTAssertEqual(days.count, 20)
        let queries = ChartCandlesEndpoint.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(Set(queries.compactMap { components in
            let items = components.queryItems ?? []
            return items.first(where: { $0.name == "interval" })?.value.flatMap { interval in
                items.first(where: { $0.name == "count" })?.value.map { "\(interval):\($0)" }
            }
        }), ["1m:200", "1d:20"])
        XCTAssertTrue(queries.allSatisfy { $0.url?.path == "/api/v1/candles" })
    }

    func testDailyCandlesCanLoadAfterMinuteRequestFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartCandlesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ChartCandlesEndpoint.reset()
        ChartCandlesEndpoint.failMinute = true

        let stock = WatchedStock(symbol: "SOXL", market: .us)
        do {
            _ = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                     interval: .minute, session: session)
            XCTFail("Minute request should fail")
        } catch {}
        let days = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                        interval: .day, session: session)
        XCTAssertEqual(days.count, 20)
    }

    @MainActor
    func testChartCacheUsesSelectedIntervalPerStockAndSharedMinuteSource() async throws {
        let recorder = ChartFetchRecorder()
        let store = StockChartStore { stock, interval in await recorder.fetch(stock, interval) }
        let samsung = WatchedStock(symbol: "005930", market: .kr)
        let apple = WatchedStock(symbol: "AAPL", market: .us)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await store.load(stock: samsung, interval: .minute, now: start)
        await store.load(stock: samsung, interval: .minute, now: start.addingTimeInterval(59))
        await store.load(stock: apple, interval: .minute, now: start.addingTimeInterval(59))
        await store.load(stock: samsung, interval: .tenMinutes, now: start.addingTimeInterval(59))
        XCTAssertEqual(store.secondsUntilRefresh(stock: samsung, interval: .minute,
                                                 now: start.addingTimeInterval(30)), 30)
        XCTAssertEqual(store.secondsUntilRefresh(stock: samsung, interval: .tenMinutes,
                                                 now: start.addingTimeInterval(30)), 570)
        await store.load(stock: samsung, interval: .minute, now: start.addingTimeInterval(60))
        await store.load(stock: samsung, interval: .tenMinutes, now: start.addingTimeInterval(660))

        let calls = await recorder.calls()
        XCTAssertEqual(calls, ["\(samsung.id):1m", "\(apple.id):1m", "\(samsung.id):1m", "\(samsung.id):1m"])

        await store.load(stock: samsung, interval: .day, now: start)
        await store.load(stock: samsung, interval: .day, now: start.addingTimeInterval(86_399))
        await store.load(stock: samsung, interval: .day, now: start.addingTimeInterval(86_400))
        let dailyCalls = (await recorder.calls()).filter { $0 == "\(samsung.id):1d" }
        XCTAssertEqual(dailyCalls.count, 2)
    }

    @MainActor
    func testTenMinuteChartDoesNotFetchEveryMinute() async {
        let recorder = ChartFetchRecorder()
        let store = StockChartStore { stock, interval in await recorder.fetch(stock, interval) }
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await store.load(stock: stock, interval: .tenMinutes, now: start)
        await store.load(stock: stock, interval: .tenMinutes, now: start.addingTimeInterval(599))
        let beforeRefresh = await recorder.calls()
        XCTAssertEqual(beforeRefresh.count, 1)
        await store.load(stock: stock, interval: .tenMinutes, now: start.addingTimeInterval(600))
        let afterRefresh = await recorder.calls()
        XCTAssertEqual(afterRefresh.count, 2)
    }

    @MainActor
    func testFailedDailyChartRequestRetriesAfterTenMinutes() async {
        let recorder = ChartFetchRecorder()
        let store = StockChartStore { stock, interval in try await recorder.fail(stock, interval) }
        let stock = WatchedStock(symbol: "AAPL", market: .us)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await store.load(stock: stock, interval: .day, now: start)
        await store.load(stock: stock, interval: .day, now: start.addingTimeInterval(599))
        let beforeRetry = await recorder.calls()
        XCTAssertEqual(beforeRetry, ["\(stock.id):1d"])
        XCTAssertTrue(store.failed.contains(.init(stock: stock, interval: .day)))
        await store.load(stock: stock, interval: .day, now: start.addingTimeInterval(600))
        let afterRetry = await recorder.calls()
        XCTAssertEqual(afterRetry, ["\(stock.id):1d", "\(stock.id):1d"])
    }

    @MainActor
    func testChartPreferencesPersistAndClampAtTwenty() throws {
        let name = "Chart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.stockChartCount, 20)
        XCTAssertEqual(preferences.stockChartInterval, .tenMinutes)
        preferences.stockChartCount = 12
        preferences.stockChartInterval = .day
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.stockChartCount, 12)
        XCTAssertEqual(reloaded.stockChartInterval, .day)
        preferences.stockChartCount = 200
        XCTAssertEqual(preferences.stockChartCount, 20)
        preferences.stockChartCount = 0
        XCTAssertEqual(preferences.stockChartCount, 1)
    }
}

private actor ChartFetchRecorder {
    private var requested: [String] = []

    func fetch(_ stock: WatchedStock, _ interval: StockChartInterval) -> [StockCandle] {
        requested.append("\(stock.id):\(interval.rawValue)")
        return []
    }

    func fail(_ stock: WatchedStock, _ interval: StockChartInterval) throws -> [StockCandle] {
        requested.append("\(stock.id):\(interval.rawValue)")
        throw TossInvestAPI.Failure.http(429)
    }

    func calls() -> [String] { requested }
}

private final class ChartCandlesEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var minuteFails = false
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var failMinute: Bool {
        get { lock.withLock { minuteFails } }
        set { lock.withLock { minuteFails = newValue } }
    }
    static func reset() { lock.withLock { recorded = []; minuteFails = false } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let interval = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "interval" })?.value
        if interval == "1m", Self.failMinute {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"not-found"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let count = interval == "1m" ? 200 : 20
        let start = ISO8601DateFormatter().date(from: "2026-03-25T09:00:00Z")!
        let formatter = ISO8601DateFormatter()
        let rows: [[String: String]] = (1...count).reversed().map { index in
            let date = start.addingTimeInterval(TimeInterval(index * (interval == "1m" ? 60 : 86_400)))
            return ["timestamp": formatter.string(from: date), "openPrice": "100",
                    "highPrice": "102", "lowPrice": "99", "closePrice": "101",
                    "volume": "5", "currency": "KRW"]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["result": ["candles": rows]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
