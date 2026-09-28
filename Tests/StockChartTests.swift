import SwiftUI
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
        let quiet = StockCandle(end: .now, open: 100, high: 100.01, low: 99.99, close: 100.005, volume: 1)
        let zoom = StockChartSection.priceDomain(for: [quiet])
        XCTAssertEqual(zoom.lowerBound, 99.9884, accuracy: 0.000001)
        XCTAssertEqual(zoom.upperBound, 100.0116, accuracy: 0.000001)
        let flat = StockCandle(end: .now, open: 100, high: 100, low: 100, close: 100, volume: 1)
        let flatDomain = StockChartSection.priceDomain(for: [flat])
        XCTAssertLessThan(flatDomain.lowerBound, 100)
        XCTAssertGreaterThan(flatDomain.upperBound, 100)
        XCTAssertLessThan(flatDomain.upperBound - flatDomain.lowerBound, 0.2)
        XCTAssertEqual(StockChartSection.priceDomain(for: []), 0...1)
    }

    func testMovingAveragesUseHiddenHistoryWithoutPartialWindowsOrFuturePrices() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var candles: [StockCandle] = (1...140).map { (index: Int) -> StockCandle in
            let price = Decimal(index)
            let end = start.addingTimeInterval(TimeInterval(index) * 86_400)
            return StockCandle(end: end, open: price, high: price, low: price, close: price, volume: 100)
        }
        for period in StockQuoteCodec.movingAveragePeriods {
            let values = StockQuoteCodec.movingAverages(for: candles, period: period)
            XCTAssertEqual(values.count, 140)
            XCTAssertTrue(values.prefix(period - 1).allSatisfy { $0 == nil })
            XCTAssertEqual(try XCTUnwrap(values[period - 1]), Double(period + 1) / 2, accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(values[139]), 140 - Double(period - 1) / 2, accuracy: 0.00001)
            XCTAssertTrue(values.suffix(20).allSatisfy { $0 != nil })
            var changed = candles
            changed[139].close = 1_000
            XCTAssertEqual(Array(values.prefix(139)), Array(StockQuoteCodec.movingAverages(for: changed, period: period).prefix(139)))
        }
        XCTAssertTrue(StockQuoteCodec.movingAverages(for: Array(candles.suffix(20)), period: 120).allSatisfy { $0 == nil })
        XCTAssertTrue(StockQuoteCodec.movingAverages(for: candles + [candles[0]], period: 5).allSatisfy { $0 == nil })
        candles[20].close = .nan
        XCTAssertTrue(StockQuoteCodec.movingAverages(for: candles, period: 5).allSatisfy { $0 == nil })
    }

    @MainActor
    func testFinnhubHoverCardDoesNotReserveChartSpace() throws {
        let domain = "StockChartHover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsStockTimingSignals = false
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        let snapshot = StockBoard.snapshot(stock: stock, quote: nil, previousClose: nil,
                                           name: nil, link: .idle)
        let store = StockChartStore(fetch: { _, _ in [] })
        let model = NotchViewModel()
        model.todoPreferences = preferences
        model.stockCharts = store

        let tossHeight = model.cardHeight(for: snapshot)
        let tossCard = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: .now,
                                                          stockCharts: store, stockPreferences: preferences))
        let tossImage = try XCTUnwrap(tossCard.cgImage)

        preferences.portfolioForecastEnabled = true
        let forecastHeight = model.cardHeight(for: snapshot)
        let forecastCard = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: .now,
                                                              stockCharts: store, stockPreferences: preferences))
        let forecastImage = try XCTUnwrap(forecastCard.cgImage)
        XCTAssertEqual(forecastHeight - tossHeight, NotchLayout.stockForecastSectionHeight)
        XCTAssertEqual(CGFloat(forecastImage.height - tossImage.height), NotchLayout.stockForecastSectionHeight)
        preferences.showsStockTimingSignals = true
        let timingCard = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: .now,
                                                            stockCharts: store, stockPreferences: preferences))
        let timingImage = try XCTUnwrap(timingCard.cgImage)
        XCTAssertEqual(model.cardHeight(for: snapshot) - forecastHeight, NotchLayout.stockTimingSectionHeight)
        XCTAssertEqual(CGFloat(timingImage.height - forecastImage.height), NotchLayout.stockTimingSectionHeight)
        preferences.portfolioForecastEnabled = false
        let historyCard = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: .now,
                                                             stockCharts: store, stockPreferences: preferences))
        let historyImage = try XCTUnwrap(historyCard.cgImage)
        XCTAssertEqual(model.cardHeight(for: snapshot) - tossHeight, NotchLayout.stockTimingSectionHeight)
        XCTAssertEqual(CGFloat(historyImage.height - tossImage.height), NotchLayout.stockTimingSectionHeight)

        preferences.stockQuoteSource = .finnhub
        let finnhubHeight = model.cardHeight(for: snapshot)
        let finnhubCard = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: .now,
                                                             stockCharts: store, stockPreferences: preferences))
        let finnhubImage = try XCTUnwrap(finnhubCard.cgImage)

        XCTAssertEqual(tossHeight - finnhubHeight, NotchLayout.stockChartSectionHeight)
        XCTAssertEqual(CGFloat(tossImage.height - finnhubImage.height), NotchLayout.stockChartSectionHeight)
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
        XCTAssertEqual(days.count, 200)
        let queries = ChartCandlesEndpoint.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(Set(queries.compactMap { components in
            let items = components.queryItems ?? []
            return items.first(where: { $0.name == "interval" })?.value.flatMap { interval in
                items.first(where: { $0.name == "count" })?.value.map { "\(interval):\($0)" }
            }
        }), ["1m:200", "1d:200"])
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
        XCTAssertEqual(days.count, 200)
    }

    func testTenMinuteHistoryUsesBoundedPaginationAndDeduplicatesInclusiveCursors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChartCandlesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ChartCandlesEndpoint.reset()
        ChartCandlesEndpoint.paginates = true
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        let minutes = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                          interval: .tenMinutes, session: session)
        XCTAssertEqual(ChartCandlesEndpoint.requests.count, 8)
        XCTAssertEqual(minutes.count, 1_593)
        XCTAssertEqual(Set(minutes.map(\.end)).count, minutes.count)
        let bars = StockQuoteCodec.tenMinuteCandles(from: minutes)
        XCTAssertTrue(StockQuoteCodec.movingAverages(for: bars, period: 120).suffix(20).allSatisfy { $0 != nil })
        XCTAssertTrue(ChartCandlesEndpoint.requests.dropFirst().allSatisfy {
            $0.url!.absoluteString.contains("%2B09:00")
        })
        ChartCandlesEndpoint.reset()
        ChartCandlesEndpoint.paginates = true
        ChartCandlesEndpoint.stalls = true
        do {
            _ = try await TossInvestAPI.chartCandles(token: "test-token", stock: stock,
                                                     interval: .tenMinutes, session: session)
            XCTFail("A non-progressing history cursor must not succeed or loop")
        } catch { XCTAssertEqual(ChartCandlesEndpoint.requests.count, 2) }
    }

    @MainActor
    func testChartCacheKeepsHistoryAndRefreshIntervalsSeparatePerStock() async throws {
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
                                                 now: start.addingTimeInterval(60)), 599)
        await store.load(stock: samsung, interval: .minute, now: start.addingTimeInterval(60))
        await store.load(stock: samsung, interval: .tenMinutes, now: start.addingTimeInterval(660))

        let calls = await recorder.calls()
        XCTAssertEqual(calls, ["\(samsung.id):1m", "\(apple.id):1m", "\(samsung.id):10m", "\(samsung.id):1m", "\(samsung.id):10m"])

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
    func testChangingAPIKeysInvalidatesChartCacheImmediately() async {
        let recorder = ChartFetchRecorder()
        let store = StockChartStore { stock, interval in await recorder.fetch(stock, interval) }
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await store.load(stock: stock, interval: .day, now: start)
        await store.load(stock: stock, interval: .day, now: start.addingTimeInterval(1), settingsRevision: 1)

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(store.secondsUntilRefresh(stock: stock, interval: .day,
                                                 now: start.addingTimeInterval(1)), 86_400)
    }

    @MainActor
    func testFinnhubNeverFetchesTossChartsAndClearsPreviousProviderCache() async {
        let recorder = ChartFetchRecorder()
        let store = StockChartStore { stock, interval in await recorder.fetch(stock, interval) }
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        await store.load(stock: stock, interval: .minute)
        XCTAssertFalse(store.entries.isEmpty)
        for interval in StockChartInterval.allCases {
            await store.load(stock: stock, interval: interval, source: .finnhub)
        }
        XCTAssertTrue(store.entries.isEmpty)
        let calls = await recorder.calls()
        XCTAssertEqual(calls, ["us:SOXL:1m"])
        await store.load(stock: stock, interval: .minute, source: .toss)
        let resumed = await recorder.calls()
        XCTAssertEqual(resumed.count, 2)
    }

    @MainActor
    func testSwitchingProviderCancelsInFlightChartWithoutRepopulatingCache() async {
        let started = expectation(description: "Toss chart started")
        let cancelled = expectation(description: "Toss chart cancelled")
        let store = StockChartStore { _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill() }
            return []
        }
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        let pending = Task { await store.load(stock: stock, interval: .minute) }
        await fulfillment(of: [started], timeout: 2)
        store.configure(source: .finnhub, settingsRevision: 1)
        await fulfillment(of: [cancelled], timeout: 2)
        await pending.value
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.loading.isEmpty)
        XCTAssertTrue(store.failed.isEmpty)
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
        XCTAssertEqual(preferences.stockMovingAveragePeriods, [5, 20])
        preferences.stockMovingAveragePeriods = [120, 5, 5, -1, 20, 60, 999]
        XCTAssertEqual(preferences.stockMovingAveragePeriods, [5, 20, 60, 120])
        XCTAssertEqual(Preferences(defaults: defaults).stockMovingAveragePeriods, [5, 20, 60, 120])
        preferences.stockMovingAveragePeriods = []
        XCTAssertTrue(Preferences(defaults: defaults).stockMovingAveragePeriods.isEmpty)
    }

    @MainActor
    func testMovingAverageChartFitsTheHoverCard() async throws {
        let name = "ChartPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.stockChartInterval = .day
        preferences.showsStockTimingSignals = false
        preferences.stockMovingAveragePeriods = [5, 20, 60, 120]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = StockChartStore { _, _ in
            (0..<200).map { index in
                // Older high prices leave SMA 60/120 far outside the quiet visible candles.
                let price = Decimal(index < 160 ? 140 : 100 + sin(Double(index) / 3) * 0.004)
                return StockCandle(end: start.addingTimeInterval(Double(index) * 86400),
                    open: price + (index % 5 == 0 ? 0 : index.isMultiple(of: 2) ? 0.0015 : -0.0015),
                    high: price + 0.003, low: price - 0.003, close: price, volume: 100)
            }
        }
        let stock = WatchedStock(symbol: "SOXL", market: .us)
        await store.load(stock: stock, interval: .day, now: start)
        let renderer = ImageRenderer(content: StockChartSection(store: store, preferences: preferences, stock: stock)
            .frame(width: 200).padding(10).background(.black).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(CGFloat(image.height), (NotchLayout.stockChartSectionHeight + 20) * 2)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/PenguinNotch-moving-averages-preview.png"))
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
    private static var paginationEnabled = false
    private static var cursorStalls = false
    static var paginates: Bool {
        get { lock.withLock { paginationEnabled } }
        set { lock.withLock { paginationEnabled = newValue } }
    }
    static var stalls: Bool {
        get { lock.withLock { cursorStalls } }
        set { lock.withLock { cursorStalls = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var failMinute: Bool {
        get { lock.withLock { minuteFails } }
        set { lock.withLock { minuteFails = newValue } }
    }
    static func reset() { lock.withLock { recorded = []; minuteFails = false; paginationEnabled = false; cursorStalls = false } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let interval = items.first(where: { $0.name == "interval" })?.value
        if interval == "1m", Self.failMinute {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"not-found"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let count = Int(items.first(where: { $0.name == "count" })?.value ?? "0")!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
        let cursor = items.first(where: { $0.name == "before" })?.value
        let end = (!Self.stalls ? cursor.flatMap { formatter.date(from: $0) } : nil)
            ?? formatter.date(from: "2026-03-25T12:20:00Z")!
        let rows: [[String: String]] = (0..<count).map { index in
            let date = end.addingTimeInterval(-TimeInterval(index * (interval == "1m" ? 60 : 86_400)))
            return ["timestamp": formatter.string(from: date), "openPrice": "100",
                    "highPrice": "102", "lowPrice": "99", "closePrice": "101",
                    "volume": "5", "currency": "KRW"]
        }
        var result: [String: Any] = ["candles": rows]
        if Self.paginates { result["nextBefore"] = rows.last!["timestamp"]! }
        let data = try! JSONSerialization.data(withJSONObject: ["result": result])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
