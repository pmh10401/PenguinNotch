import XCTest
@testable import Codenotch

final class StockQuoteTests: XCTestCase {
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
        XCTAssertEqual(rising.ringLabel, "005930")
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
}
