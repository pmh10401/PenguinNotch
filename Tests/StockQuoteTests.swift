import Security
import XCTest
@testable import PenguinNotch

final class StockQuoteTests: XCTestCase {
    func testQuoteProviderSupportDoesNotFallBackToAnotherProvider() {
        let korean = WatchedStock(symbol: "005930", market: .kr)
        let us = WatchedStock(symbol: "AAPL", market: .us)
        XCTAssertTrue(StockQuoteSource.toss.supports(korean))
        XCTAssertTrue(StockQuoteSource.toss.supports(us))
        XCTAssertTrue(StockQuoteSource.finnhub.supports(us))
        XCTAssertFalse(StockQuoteSource.finnhub.supports(korean))
        let snapshot = StockBoard.snapshot(stock: korean, quote: nil, previousClose: nil,
                                           name: nil, link: .failed("Unsupported"), source: .finnhub)
        XCTAssertEqual(snapshot.plan, "Finnhub")
        XCTAssertEqual(snapshot.status, .unsupported("Unsupported"))
        XCTAssertEqual(StockBoard.placeholder(message: "Add a stock", source: .finnhub).plan, "Finnhub")
    }

    func testKrxCompanyNamesResolveToStoredCodes() {
        let directory = KoreanStockDirectory.shared
        XCTAssertGreaterThan(directory.companies.count, 2_000)
        XCTAssertEqual(directory.resolve("삼성전자"), WatchedStock(symbol: "005930", market: .kr))
        XCTAssertEqual(directory.resolve(" SK하이닉스 "), WatchedStock(symbol: "000660", market: .kr))
        XCTAssertEqual(directory.resolve("005930"), WatchedStock(symbol: "005930", market: .kr))
        XCTAssertTrue(directory.search("삼성").contains { $0.code == "005930" })
        XCTAssertNil(directory.resolve("존재하지않는종목"))
    }

    func testSymbolsSeparateKoreanCodesFromUsTickers() {
        XCTAssertEqual(WatchedStock.parse("005930"), WatchedStock(symbol: "005930", market: .kr))
        XCTAssertEqual(WatchedStock.parse(" 0101n0 "), WatchedStock(symbol: "0101N0", market: .kr))
        XCTAssertEqual(WatchedStock.parse("aapl"), WatchedStock(symbol: "AAPL", market: .us))
        XCTAssertEqual(WatchedStock.parse("US:BRK.B"), WatchedStock(symbol: "BRK.B", market: .us))
        XCTAssertEqual(WatchedStock.parse("KR:005930"), WatchedStock(symbol: "005930", market: .kr))
        XCTAssertNil(WatchedStock.parse("KR:AAPL"))
        XCTAssertNil(WatchedStock.parse(""))
        XCTAssertNil(WatchedStock.parse("@@@"))
        let stored = WatchedStock.parseList(["005930", "aapl", "005930", "not a symbol"])
        XCTAssertEqual(stored.map(\.id), ["kr:005930", "us:AAPL"])
    }

    func testPriceAndTradePayloadsBecomeTicks() throws {
        let prices = Data(#"{"result":[{"symbol":"005930","lastPrice":"72000","currency":"KRW","timestamp":"2026-03-25T09:30:42.000+09:00"},{"symbol":"AAPL","lastPrice":243.26,"currency":"USD"}]}"#.utf8)
        let quotes = StockQuoteCodec.prices(from: prices)
        XCTAssertEqual(quotes["kr:005930"]?.price, 72000)
        XCTAssertEqual(quotes["kr:005930"]?.currency, "KRW")
        XCTAssertEqual(quotes["us:AAPL"]?.price, Decimal(string: "243.26"))
        let frame = #"{"type":"message","topic":"trade:kr:005930","data":{"price":"72100","volume":"12","timestamp":"2026-03-25T09:31:00.000+09:00","currency":"KRW"}}"#
        guard case .tick(let id, let tick) = StockQuoteCodec.event(from: frame) else {
            return XCTFail("expected a trade")
        }
        XCTAssertEqual(id, "kr:005930")
        XCTAssertEqual(tick.price, 72100)
        XCTAssertEqual(tick.volume, 12)
        if case .pong = StockQuoteCodec.event(from: #"{"type":"pong"}"#) {} else { XCTFail("expected pong") }
    }

    func testCurrentPricesUseOneRequestForTwoHundredSymbols() async throws {
        let symbols = (0..<200).map { "T\($0)" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockPricesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StockPricesEndpoint.reset()

        let quotes = try await TossInvestAPI.prices(token: "test-token", symbols: symbols, session: session)

        XCTAssertEqual(quotes.count, 200)
        XCTAssertEqual(quotes["us:T199"]?.price, 199)
        XCTAssertEqual(StockPricesEndpoint.requests.count, 1)
        let request = try XCTUnwrap(StockPricesEndpoint.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/prices")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "symbols" })?.value, symbols.joined(separator: ","))
    }

    func testFinnhubQuoteUsesHeaderAndRejectsInvalidPrices() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinnhubQuoteEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FinnhubQuoteEndpoint.payload = #"{"c":243.26,"pc":240.5,"t":1770000000}"#
        let (tick, close) = try await FinnhubAPI.quote(symbol: "AAPL", key: "test-key", session: session)
        XCTAssertEqual(tick.price, Decimal(string: "243.26"))
        XCTAssertEqual(close, Decimal(string: "240.5"))
        XCTAssertEqual(tick.currency, "USD")
        XCTAssertEqual(FinnhubQuoteEndpoint.lastRequest?.value(forHTTPHeaderField: "X-Finnhub-Token"), "test-key")
        XCTAssertEqual(FinnhubQuoteEndpoint.lastRequest?.url?.query, "symbol=AAPL")
        XCTAssertFalse(FinnhubQuoteEndpoint.lastRequest!.url!.absoluteString.contains("test-key"))

        FinnhubQuoteEndpoint.payload = #"{"c":10,"pc":0,"t":1770000000}"#
        let (newTick, missingClose) = try await FinnhubAPI.quote(symbol: "AAPL", key: "test-key", session: session)
        XCTAssertEqual(newTick.price, 10)
        XCTAssertNil(missingClose)

        FinnhubQuoteEndpoint.payload = #"{"c":0,"pc":240.5,"t":0}"#
        do {
            _ = try await FinnhubAPI.quote(symbol: "AAPL", key: "test-key", session: session)
            XCTFail("Zero price must not appear as a quote")
        } catch FinnhubAPI.Failure.invalidResponse {}
    }

    func testSubscriptionDeclaresEachMarketOnce() throws {
        let json = StockQuoteCodec.subscriptionJSON([
            WatchedStock(symbol: "005930", market: .kr),
            WatchedStock(symbol: "000660", market: .kr),
            WatchedStock(symbol: "AAPL", market: .us)
        ])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows[0]["id"] as? String, "req-1")
        XCTAssertEqual(rows[1]["type"] as? String, "trade:kr")
        XCTAssertEqual(rows[1]["codes"] as? [String], ["005930", "000660"])
        XCTAssertEqual(rows[2]["type"] as? String, "trade:us")
        XCTAssertEqual(rows[2]["codes"] as? [String], ["AAPL"])
    }

    func testEachSymbolIsItsOwnRingScaledToThirtyPercent() {
        let samsung = WatchedStock(symbol: "005930", market: .kr)
        let apple = WatchedStock(symbol: "AAPL", market: .us)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 9, minute: 30))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let older = calendar.date(byAdding: .day, value: -2, to: today)!
        let previous = StockQuoteCodec.previousClose(
            closes: [(today, 78000), (yesterday, 60000), (older, 50000)],
            priceTime: today, timeZone: calendar.timeZone)
        XCTAssertEqual(previous, Decimal(60000))
        let beforeOpen = StockQuoteCodec.previousClose(
            closes: [(yesterday, 60000), (older, 50000)],
            priceTime: today, timeZone: calendar.timeZone)
        XCTAssertEqual(beforeOpen, Decimal(60000))
        XCTAssertEqual(StockQuoteCodec.ringFraction(for: Decimal(string: "0.30")!), 1)
        XCTAssertEqual(StockQuoteCodec.ringFraction(for: Decimal(string: "-0.15")!), 0.5, accuracy: 0.0001)
        XCTAssertEqual(StockQuoteCodec.ringFraction(for: Decimal(string: "0.45")!), 1)
        let rising = StockBoard.snapshot(stock: samsung,
                                         quote: StockTick(price: 78000, volume: 1, timestamp: today, currency: "KRW"),
                                         previousClose: 60000, name: "삼성전자", link: .live,
                                         locale: Locale(identifier: "en_US_POSIX"))
        let falling = StockBoard.snapshot(stock: apple,
                                          quote: StockTick(price: Decimal(string: "90")!, volume: nil, timestamp: today, currency: "USD"),
                                          previousClose: 100, name: nil, link: .live,
                                          locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(rising.id, "widget-stock:kr:005930")
        XCTAssertEqual(falling.id, "widget-stock:us:AAPL")
        XCTAssertEqual(rising.ringLabel, "삼성전자")
        XCTAssertEqual(rising.headlineText, "+30.00%")
        XCTAssertEqual(rising.ringFraction, 1)
        XCTAssertEqual(rising.bandOverride, .ample)
        XCTAssertEqual(falling.headlineText, "-10.00%")
        XCTAssertEqual(falling.ringFraction ?? 0, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(falling.bandOverride, .critical)
        XCTAssertEqual(rising.displayName, "삼성전자")
        let payload = Data(#"{"result":{"candles":[{"timestamp":"2026-03-25T00:00:00+09:00","closePrice":"72000"},{"timestamp":"2026-03-24T00:00:00+09:00","closePrice":"71600"}]}}"#.utf8)
        let closes = StockQuoteCodec.dailyCloses(from: payload)
        let traded = ISO8601DateFormatter()
        traded.formatOptions = [.withInternetDateTime]
        let session = traded.date(from: "2026-03-25T09:30:42+09:00")!
        let base = StockQuoteCodec.previousClose(closes: closes, priceTime: session,
                                                 timeZone: TimeZone(identifier: "Asia/Seoul")!)
        XCTAssertEqual(base, Decimal(71600))
        let rate = StockQuoteCodec.changeRate(price: 72000, previousClose: 71600)
        XCTAssertEqual(StockQuoteCodec.ringFraction(for: rate!), 0.0186, accuracy: 0.001)
        let modest = StockBoard.snapshot(stock: samsung,
                                         quote: StockTick(price: 72000, volume: nil, timestamp: session, currency: "KRW"),
                                         previousClose: base, name: nil, link: .live,
                                         locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(modest.bandOverride, .ample)
        XCTAssertEqual(modest.headlineID, "change")
    }

    @MainActor
    func testRegisteredSymbolsPersistAndCapAtThirty() throws {
        let name = "Stocks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.showsStocks)
        XCTAssertTrue(preferences.addStockSymbol("005930"))
        XCTAssertTrue(preferences.addStockSymbol("aapl"))
        XCTAssertFalse(preferences.addStockSymbol("not a symbol"))
        for index in 0..<40 { preferences.addStockSymbol("US:T\(index)") }
        XCTAssertEqual(preferences.stockSymbols.count, 30)
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.stockSymbols.first, "kr:005930")
        XCTAssertEqual(reloaded.stockSymbols.dropFirst().first, "us:AAPL")
        preferences.showsStocks = true
        preferences.notchMeterStyle = .bar
        let reloadedStyle = Preferences(defaults: defaults)
        XCTAssertTrue(reloadedStyle.showsStocks)
        XCTAssertEqual(reloadedStyle.notchMeterStyle, .bar)
        preferences.removeStockSymbol("kr:005930")
        XCTAssertFalse(preferences.stockSymbols.contains("kr:005930"))
    }

    func testLegacyTossCredentialsMoveWithoutLosingValues() throws {
        let suffix = UUID().uuidString
        let oldService = "penguinnotch-test.old.\(suffix)"
        let newService = "penguinnotch-test.new.\(suffix)"
        let accounts = ["client-id", "client-secret"]
        func query(_ service: String, _ account: String) -> [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        }
        defer {
            for account in accounts {
                _ = SecItemDelete(query(oldService, account) as CFDictionary)
                _ = SecItemDelete(query(newService, account) as CFDictionary)
            }
        }
        for account in accounts {
            var item = query(oldService, account)
            item[kSecValueData] = Data(account.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw XCTSkip("No writable Keychain for the migration check")
            }
        }

        TossCredentials.migrateLegacyItems(from: oldService, to: newService)
        for account in accounts {
            XCTAssertNil(KeychainItem.newest(service: oldService, account: account))
            XCTAssertEqual(KeychainItem.read(service: newService, account: account), account)
        }
    }
}

private final class StockPricesEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let rows: [[String: String]] = (0..<200).map {
            ["symbol": "T\($0)", "lastPrice": "\($0)", "currency": "USD"]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["result": rows])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class FinnhubQuoteEndpoint: URLProtocol, @unchecked Sendable {
    static var payload = ""
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
