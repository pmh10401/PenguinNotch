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

    func testUSPreviousCloseWhenNewestDailyBarIsAfterQuote() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockPricesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StockPricesEndpoint.reset()
        let quoteTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T03:05:48Z"))

        let close = try await TossInvestAPI.previousClose(
            token: "test-token", stock: WatchedStock(symbol: "SOXL", market: .us),
            priceTime: quoteTime, session: session)

        XCTAssertEqual(close, 100)
        let request = try XCTUnwrap(StockPricesEndpoint.requests.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "count" })?.value, "3")
    }

    func testPreviousCloseSkipsFutureBarWithoutSkippingFriday() throws {
        let iso = ISO8601DateFormatter()
        let friday = try XCTUnwrap(iso.date(from: "2026-09-25T04:00:00Z"))
        let closes: [(date: Date, close: Decimal)] = [
            (try XCTUnwrap(iso.date(from: "2026-09-28T04:00:00Z")), 150),
            (friday, Decimal(string: "151.45")!),
            (try XCTUnwrap(iso.date(from: "2026-09-24T04:00:00Z")), Decimal(string: "146.33")!)
        ]
        let close = StockQuoteCodec.previousClose(closes: closes,
            priceTime: try XCTUnwrap(iso.date(from: "2026-09-28T00:30:00Z")),
            timeZone: StockQuoteCodec.timeZone(for: .us))
        XCTAssertEqual(close, Decimal(string: "151.45"))
        XCTAssertEqual(StockQuoteCodec.formatChange(try XCTUnwrap(StockQuoteCodec.changeRate(
            price: Decimal(string: "144.1")!, previousClose: try XCTUnwrap(close))),
            locale: Locale(identifier: "en_US_POSIX")), "-4.85%")
        XCTAssertEqual(StockQuoteCodec.previousClose(closes: [closes[0], closes[1]],
            priceTime: friday.addingTimeInterval(2 * 86400),
            timeZone: StockQuoteCodec.timeZone(for: .us)), Decimal(string: "151.45"))
    }

    func testUntimestampedUSQuoteNeverShowsAPercentageOrInventedTradeTime() throws {
        let data = Data(#"{"result":[{"symbol":"SOXL","lastPrice":"144.1","currency":"USD","timestamp":null}]}"#.utf8)
        let tick = try XCTUnwrap(StockQuoteCodec.prices(from: data)["us:SOXL"])
        let snapshot = StockBoard.snapshot(stock: WatchedStock(symbol: "SOXL", market: .us),
            quote: tick, previousClose: Decimal(string: "146.33"), name: nil, link: .live,
            locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(snapshot.headlineText, "$144.10")
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "change" })?.usedText, "—")
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "traded" })?.detail, "Trade time unavailable")
        XCTAssertTrue(StockQuoteCodec.prices(from: data, requireTimestamp: true).isEmpty)
    }

    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func marketCalendar(today: String = "{}", previous: String = "{}", next: String = "{}") throws -> MarketSessions {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MarketSessions.self,
            from: Data("{\"today\":\(today),\"previousBusinessDay\":\(previous),\"nextBusinessDay\":\(next)}".utf8))
    }

    private let mondaySessions = #"{"date":"2026-09-28","dayMarket":{"startTime":"2026-09-28T09:00:00+09:00","endTime":"2026-09-28T16:50:00+09:00"},"preMarket":{"startTime":"2026-09-28T17:00:00+09:00","endTime":"2026-09-28T22:30:00+09:00"},"regularMarket":{"startTime":"2026-09-28T22:30:00+09:00","endTime":"2026-09-29T05:00:00+09:00"},"afterMarket":{"startTime":"2026-09-29T05:00:00+09:00","endTime":"2026-09-29T09:00:00+09:00"}}"#
    private let fridaySessions = #"{"date":"2026-09-25","regularMarket":{"startTime":"2026-09-25T13:30:00Z","endTime":"2026-09-25T20:00:00Z"},"afterMarket":{"startTime":"2026-09-25T20:00:00Z","endTime":"2026-09-26T00:00:00Z"}}"#

    func testSundayNightUsesNextBusinessDayAndFridayClose() throws {
        let calendar = try marketCalendar(next: mondaySessions)
        let quote = StockTick(price: Decimal(string: "144.1")!, volume: nil,
                             timestamp: instant("2026-09-28T00:30:00Z"), currency: "USD")
        let session = try XCTUnwrap(StockQuoteCodec.usSession(at: quote.timestamp, calendar: calendar))
        XCTAssertEqual(session.phase, .day)
        XCTAssertEqual(session.tradingDay, instant("2026-09-28T04:00:00Z"))
        let daily = StockDailyCloses(values: [(instant("2026-09-28T04:00:00Z"), 144),
            (instant("2026-09-25T04:00:00Z"), Decimal(string: "151.45")!),
            (instant("2026-09-24T04:00:00Z"), Decimal(string: "146.33")!)], requestedAt: quote.timestamp)
        let basis = try XCTUnwrap(StockQuoteCodec.changeBasis(daily: daily, quote: quote, market: .us, session: session))
        XCTAssertEqual(basis.close, Decimal(string: "151.45"))
        XCTAssertEqual(basis.date, instant("2026-09-25T04:00:00Z"))
        let snapshot = StockBoard.snapshot(stock: WatchedStock(symbol: "SOXL", market: .us), quote: quote,
            previousClose: basis.close, name: nil, link: .live, locale: Locale(identifier: "en_US_POSIX"),
            quoteSession: session, basisDate: basis.date)
        XCTAssertEqual(snapshot.headlineText, "-4.85%")
        XCTAssertTrue(snapshot.windows.first { $0.id == "traded" }?.detail?.contains("2026-09-27 20:30:00 ET") == true)
        XCTAssertTrue(snapshot.windows.first { $0.id == "previous" }?.detail?.contains("2026-09-25 · $151.45") == true)
        XCTAssertTrue(snapshot.windows.first { $0.id == "session" }?.detail?.contains("Day market") == true)
        XCTAssertTrue(snapshot.windows.first { $0.id == "change" }?.label.contains("previous regular close") == true)
        // The documented ten-minute gap belongs to no phase; calendar absence
        // and the after-market's exclusive end must also remain unknown.
        XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-09-28T07:55:00Z"), calendar: calendar))
        XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-09-29T00:00:00Z"), calendar: calendar))
        XCTAssertNil(StockQuoteCodec.usSession(at: quote.timestamp, calendar: nil))
        XCTAssertNil(StockQuoteCodec.changeBasis(daily: daily, quote: quote, market: .us, session: nil))
        let unknown = StockBoard.snapshot(stock: WatchedStock(symbol: "SOXL", market: .us), quote: quote,
            previousClose: 146, name: nil, link: .live, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(unknown.headlineText, "$144.10")
        XCTAssertEqual(unknown.windows.first { $0.id == "session" }?.detail, "Session unavailable")
    }

    func testFridayAfterHoursNeedsFreshSameDayRegularClose() throws {
        let calendar = try marketCalendar(previous: fridaySessions)
        let quote = StockTick(price: Decimal(string: "144.1")!, volume: nil,
                             timestamp: instant("2026-09-25T20:01:00Z"), currency: "USD")
        let phase = try XCTUnwrap(StockQuoteCodec.usSession(at: quote.timestamp, calendar: calendar))
        XCTAssertEqual(phase.phase, .after)
        let values: [(date: Date, close: Decimal)] = [
            (instant("2026-09-25T04:00:00Z"), Decimal(string: "151.45")!),
            (instant("2026-09-24T04:00:00Z"), Decimal(string: "146.33")!)]
        let stale = StockDailyCloses(values: values, requestedAt: instant("2026-09-25T19:59:59Z"))
        XCTAssertNil(StockQuoteCodec.changeBasis(daily: stale, quote: quote, market: .us, session: phase))
        let fresh = StockDailyCloses(values: values, requestedAt: instant("2026-09-25T20:00:00Z"))
        let basis = try XCTUnwrap(StockQuoteCodec.changeBasis(daily: fresh, quote: quote, market: .us, session: phase))
        XCTAssertEqual(basis.close, Decimal(string: "151.45"))
        let missing = StockDailyCloses(values: [values[1]], requestedAt: fresh.requestedAt)
        XCTAssertNil(StockQuoteCodec.changeBasis(daily: missing, quote: quote, market: .us, session: phase))
        let before = StockTick(price: 145, volume: nil, timestamp: instant("2026-09-25T19:59:00Z"), currency: "USD")
        let regular = try XCTUnwrap(StockQuoteCodec.usSession(at: before.timestamp, calendar: calendar))
        XCTAssertEqual(regular.phase, .regular)
        XCTAssertEqual(StockQuoteCodec.changeBasis(daily: stale, quote: before, market: .us, session: regular)?.close,
                       Decimal(string: "146.33"))
        let snapshot = StockBoard.snapshot(stock: WatchedStock(symbol: "SOXL", market: .us), quote: quote,
            previousClose: basis.close, name: nil, link: .live, quoteSession: phase, basisDate: basis.date)
        XCTAssertTrue(snapshot.windows.first { $0.id == "change" }?.label.contains("same-day regular close") == true)
    }

    func testOfficialSessionTimesRespectDSTEarlyCloseAndPhaseTransitions() throws {
        let early = #"{"regularMarket":{"startTime":"2026-11-27T09:30:00-05:00","endTime":"2026-11-27T13:00:00-05:00"},"afterMarket":{"startTime":"2026-11-27T13:00:00-05:00","endTime":"2026-11-27T17:00:00-05:00"}}"#
        let calendar = try marketCalendar(today: early, next: mondaySessions)
        XCTAssertEqual(StockQuoteCodec.usSession(at: instant("2026-11-27T17:59:59Z"), calendar: calendar)?.phase, .regular)
        let after = try XCTUnwrap(StockQuoteCodec.usSession(at: instant("2026-11-27T18:00:00Z"), calendar: calendar))
        XCTAssertEqual(after.phase, .after)
        XCTAssertEqual(after.tradingDay, instant("2026-11-27T05:00:00Z"))
        XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-11-27T22:00:00Z"), calendar: calendar))
        XCTAssertEqual(StockQuoteCodec.usSession(at: instant("2026-09-28T08:00:00Z"), calendar: calendar)?.phase, .pre)
        let quote = StockTick(price: 144, volume: nil, timestamp: instant("2026-09-28T13:30:00Z"), currency: "USD")
        let regular = try XCTUnwrap(StockQuoteCodec.usSession(at: quote.timestamp, calendar: calendar))
        XCTAssertEqual(regular.phase, .regular)
        let preFetched = StockDailyCloses(values: [(instant("2026-09-25T04:00:00Z"), 151)],
                                         requestedAt: instant("2026-09-28T13:29:59Z"))
        XCTAssertNil(StockQuoteCodec.changeBasis(daily: preFetched, quote: quote, market: .us, session: regular))
    }

    func testTossPercentTruncatesWhileFinnhubKeepsRounding() throws {
        let time = instant("2026-09-28T00:30:00Z")
        let session = try XCTUnwrap(StockQuoteCodec.usSession(at: time, calendar: try marketCalendar(next: mondaySessions)))
        for (price, toss, finnhub) in [("144.09", "-4.85%", "-4.86%"), ("144.11", "-4.84%", "-4.85%"),
                                      ("144.12", "-4.83%", "-4.84%"), ("152.2", "+0.49%", "+0.50%")] {
            let quote = StockTick(price: Decimal(string: price)!, volume: nil, timestamp: time, currency: "USD")
            for source in StockQuoteSource.allCases {
                let snapshot = StockBoard.snapshot(stock: WatchedStock(symbol: "SOXL", market: .us), quote: quote,
                    previousClose: Decimal(string: "151.45"), name: nil, link: .live,
                    locale: Locale(identifier: "en_US_POSIX"), source: source, quoteSession: session)
                XCTAssertEqual(snapshot.headlineText, source == .toss ? toss : finnhub, "\(source): \(price)")
            }
        }
    }

    func testQuoteTimestampsRequireFullTimeAndZoneWhileCandlesKeepDateOnly() throws {
        let base = instant("2026-09-28T00:30:00Z")
        let samples: [(String, Date?)] = [
            ("2026-09-28T00:30:00Z", base),
            ("2026-09-28T09:30:00+09:00", base),
            ("2026-09-27T20:30:00.125-04:00", base.addingTimeInterval(0.125)),
            ("2026-09-28", nil), ("2026-09-28T00:30:00", nil),
            ("2026-09-28T00:30Z", nil), ("2026-09-28T09:30:00+0900", nil),
            ("2026-09-28T99:30:00Z", nil)
        ]
        for (timestamp, expected) in samples {
            let row = ["symbol": "SOXL", "lastPrice": "144.1", "currency": "USD", "timestamp": timestamp]
            let data = try JSONSerialization.data(withJSONObject: ["result": [row]])
            let tick = try XCTUnwrap(StockQuoteCodec.prices(from: data)["us:SOXL"])
            XCTAssertEqual(tick.price, Decimal(string: "144.1"))
            XCTAssertEqual(tick.hasTimestamp, expected != nil, timestamp)
            XCTAssertEqual(tick.timestamp, expected ?? .distantPast, timestamp)
            XCTAssertEqual(StockQuoteCodec.prices(from: data, requireTimestamp: true).isEmpty, expected == nil, timestamp)
            let frame = "{\"type\":\"message\",\"topic\":\"trade:us:SOXL\",\"data\":{\"price\":\"144.1\",\"currency\":\"USD\",\"timestamp\":\"\(timestamp)\"}}"
            guard case .tick(_, let trade) = StockQuoteCodec.event(from: frame) else { return XCTFail("Missing price") }
            XCTAssertEqual(trade.hasTimestamp, expected != nil, timestamp)
            XCTAssertEqual(trade.timestamp, expected ?? .distantPast, timestamp)
        }
        let daily = Data(#"{"result":{"candles":[{"timestamp":"2026-09-28","openPrice":"144","highPrice":"145","lowPrice":"143","closePrice":"144.1","volume":"10"}]}}"#.utf8)
        XCTAssertEqual(StockQuoteCodec.dailyCloses(from: daily).first?.date, instant("2026-09-27T15:00:00Z"))
        XCTAssertEqual(StockQuoteCodec.candles(from: daily)?.first?.end, instant("2026-09-27T15:00:00Z"))
    }

    func testUSSessionRejectsInvalidOverlappingAndAmbiguousMatches() throws {
        let regular = #""regularMarket":{"startTime":"2026-09-28T13:30:00Z","endTime":"2026-09-28T20:00:00Z"}"#
        for (field, start, end, quote) in [
            ("dayMarket", "12:00:00", "14:00:00", "12:30:00"),
            ("preMarket", "12:00:00", "14:00:00", "12:30:00"),
            ("afterMarket", "19:00:00", "21:00:00", "20:30:00"),
            ("dayMarket", "08:00:00", "07:00:00", "07:30:00")
        ] {
            let day = "{\(regular),\"\(field)\":{\"startTime\":\"2026-09-28T\(start)Z\",\"endTime\":\"2026-09-28T\(end)Z\"}}"
            XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-09-28T\(quote)Z"),
                                                  calendar: try marketCalendar(today: day)), field)
        }
        let overlap = "{\(regular)," + #""dayMarket":{"startTime":"2026-09-28T00:00:00Z","endTime":"2026-09-28T08:00:00Z"},"preMarket":{"startTime":"2026-09-28T07:00:00Z","endTime":"2026-09-28T13:30:00Z"}}"#
        XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-09-28T07:30:00Z"),
                                              calendar: try marketCalendar(today: overlap)))
        let badRegular = "{" + regular.replacingOccurrences(of: "20:00:00", with: "13:00:00") + "}"
        XCTAssertNil(StockQuoteCodec.usSession(at: instant("2026-09-28T13:15:00Z"),
                                              calendar: try marketCalendar(today: badRegular)))
        let quote = instant("2026-09-28T00:30:00Z")
        let conflicting = mondaySessions.replacingOccurrences(of: "22:30:00", with: "23:00:00")
        XCTAssertNil(StockQuoteCodec.usSession(at: quote,
            calendar: try marketCalendar(today: conflicting, next: mondaySessions)))
        // Repeated aliases for the same official context are not ambiguous.
        XCTAssertEqual(StockQuoteCodec.usSession(at: quote,
            calendar: try marketCalendar(today: mondaySessions, next: mondaySessions))?.phase, .day)
    }

    func testQuoteOrderingRejectsFutureOlderAndUndatedReplacement() throws {
        let now = instant("2026-09-28T00:30:00Z")
        let current = StockTick(price: 144, volume: nil, timestamp: now, currency: "USD")
        var incoming = current
        incoming.timestamp = now.addingTimeInterval(-1)
        XCTAssertFalse(StockQuoteCodec.accepts(incoming, replacing: current, now: now))
        incoming.timestamp = now.addingTimeInterval(0.001)
        XCTAssertFalse(StockQuoteCodec.accepts(incoming, replacing: nil, now: now))
        XCTAssertTrue(StockQuoteCodec.accepts(current, replacing: nil, now: now))
        let frame = #"{"type":"message","topic":"trade:us:SOXL","data":{"price":"144.1","currency":"USD","timestamp":null}}"#
        guard case .tick(_, let undated) = StockQuoteCodec.event(from: frame) else { return XCTFail("Missing price") }
        XCTAssertFalse(undated.hasTimestamp)
        XCTAssertEqual(undated.timestamp, .distantPast)
        XCTAssertTrue(StockQuoteCodec.accepts(undated, replacing: nil, now: now))
        XCTAssertFalse(StockQuoteCodec.accepts(undated, replacing: current, now: now))
        XCTAssertTrue(StockQuoteCodec.accepts(current, replacing: undated, now: now))
    }

    func testQuoteDailyAndCalendarRequestsAreFreshPublicAndAdjusted() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockPricesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StockPricesEndpoint.reset(calendar: "{\"result\":{\"today\":{},\"previousBusinessDay\":{},\"nextBusinessDay\":\(mondaySessions)}}")
        let before = Date()
        let daily = try await TossInvestAPI.quoteCloses(token: "test-token", stock: WatchedStock(symbol: "SOXL", market: .us), session: session)
        let calendar = try await TossInvestAPI.marketSessions(token: "test-token", market: .us,
            at: instant("2026-09-28T00:30:00Z"), session: session)
        XCTAssertEqual(daily.values.count, 3)
        XCTAssertGreaterThanOrEqual(daily.requestedAt, before)
        XCTAssertLessThanOrEqual(daily.requestedAt, try XCTUnwrap(StockPricesEndpoint.firstRequestAt))
        XCTAssertEqual(StockQuoteCodec.usSession(at: instant("2026-09-28T00:30:00Z"), calendar: calendar)?.phase, .day)
        XCTAssertEqual(StockPricesEndpoint.requests.count, 2)
        for request in StockPricesEndpoint.requests {
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            if request.url?.path == "/api/v1/candles" {
                XCTAssertEqual(query.first { $0.name == "adjusted" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "count" }?.value, "3")
                XCTAssertEqual(query.first { $0.name == "interval" }?.value, "1d")
            } else {
                XCTAssertEqual(request.url?.path, "/api/v1/market-calendar/US")
                XCTAssertEqual(query.first { $0.name == "date" }?.value, "2026-09-27")
            }
        }
    }

    @MainActor
    func testRESTQuoteSurvivesImmediateWebSocketFailure() async throws {
        let name = "StockREST.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.stockSymbols = ["us:SOXL"]
        preferences.showsStocks = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockPricesEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StockPricesEndpoint.reset(delayedQuote: true)
        let monitor = StockQuotesMonitor(preferences: preferences, session: session,
            loadCredentials: { ("monitor-\(name)", "synthetic-secret") },
            stream: { _, _, _ in throw TossInvestAPI.Failure.http(503) })
        defer { monitor.stop() }
        let displayed = expectation(description: "REST remains usable with the socket unavailable")
        let subscription = monitor.$snapshots.sink { snapshots in
            if snapshots.first?.windows.first(where: { $0.id == "price" })?.usedText == "$144.10" {
                displayed.fulfill()
            }
        }
        defer { subscription.cancel() }
        await fulfillment(of: [displayed], timeout: 2)
    }

    @MainActor
    func testTossQuoteAndChartShareOneTokenAndRenewAfterUnauthorizedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TossTokenEndpoint.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        TossTokenEndpoint.reset()
        let clientID = "test-\(UUID().uuidString)"

        async let quoteToken = TossInvestAPI.accessToken(clientID: clientID, clientSecret: "test-secret", session: session)
        async let chartToken = TossInvestAPI.accessToken(clientID: clientID, clientSecret: "test-secret", session: session)
        let (quote, chart) = try await (quoteToken, chartToken)
        XCTAssertEqual(quote.value, chart.value)
        XCTAssertEqual(TossTokenEndpoint.tokenRequests, 1)

        TossTokenEndpoint.rejectNextPrice()
        do {
            _ = try await TossInvestAPI.prices(token: quote.value, symbols: ["SOXL"], session: session)
            XCTFail("An unauthorized quote must invalidate the shared token")
        } catch TossInvestAPI.Failure.http(401) {}

        let renewed = try await TossInvestAPI.accessToken(clientID: clientID, clientSecret: "test-secret", session: session)
        XCTAssertNotEqual(renewed.value, quote.value)
        XCTAssertEqual(TossTokenEndpoint.tokenRequests, 2)
        let prices = try await TossInvestAPI.prices(token: renewed.value, symbols: ["SOXL"], session: session)
        XCTAssertEqual(prices["us:SOXL"]?.price, Decimal(string: "35.81"))
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
                                          locale: Locale(identifier: "en_US_POSIX"), source: .finnhub)
        XCTAssertEqual(rising.id, "widget-stock:kr:005930")
        XCTAssertEqual(falling.id, "widget-stock:us:AAPL")
        XCTAssertEqual(rising.ringLabel, "삼성전자")
        XCTAssertEqual(rising.headlineText, "+30.00%")
        XCTAssertEqual(rising.windows.first(where: { $0.id == "price" })?.usedText, "78,000")
        XCTAssertEqual(rising.ringFraction, 1)
        XCTAssertEqual(rising.bandOverride, .ample)
        XCTAssertEqual(falling.headlineText, "-10.00%")
        XCTAssertEqual(falling.ringFraction ?? 0, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(falling.bandOverride, .critical)
        XCTAssertEqual(rising.displayName, "삼성전자")
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(StockBoard.displayText(for: falling, at: start, since: start, interval: 3), "-10.00%")
        XCTAssertEqual(StockBoard.displayText(for: falling, at: start.addingTimeInterval(2.9), since: start, interval: 3), "-10.00%")
        XCTAssertEqual(StockBoard.displayText(for: falling, at: start.addingTimeInterval(3), since: start, interval: 3), "$90.00")
        XCTAssertEqual(StockBoard.displayText(for: falling, at: start.addingTimeInterval(6), since: start, interval: 3), "-10.00%")
        let noClose = StockBoard.snapshot(stock: apple,
                                          quote: StockTick(price: 90, volume: nil, timestamp: today, currency: "USD"),
                                          previousClose: nil, name: nil, link: .live,
                                          locale: Locale(identifier: "en_US_POSIX"), source: .finnhub)
        XCTAssertEqual(noClose.headlineID, "change")
        XCTAssertEqual(noClose.headlineText, "—")
        XCTAssertEqual(noClose.windows.first(where: { $0.id == "price" })?.usedText, "$90.00")
        XCTAssertEqual(StockBoard.displayText(for: noClose, at: start.addingTimeInterval(3),
                                               since: start, interval: 3), "—")
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
        XCTAssertEqual(preferences.stockDisplayInterval, 3)
        preferences.stockDisplayInterval = 5
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.stockDisplayInterval, 5)
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

    @MainActor
    func testStockReorderPersistsWithoutMovingOtherNotchItems() throws {
        let name = "StockOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        for symbol in ["005930", "AAPL", "SOXL"] { XCTAssertTrue(preferences.addStockSymbol(symbol)) }

        XCTAssertTrue(preferences.moveStockSymbol("us:SOXL", onto: "kr:005930"))
        XCTAssertEqual(preferences.stockSymbols, ["us:SOXL", "kr:005930", "us:AAPL"])
        XCTAssertTrue(preferences.providerOrder.isEmpty)

        preferences.providerOrder = ["claude", "widget-stock:us:SOXL", "system-cpu",
                                     "widget-stock:kr:005930", "widget-calendar"]
        XCTAssertEqual(preferences.orderedStocks.map(\.id), ["us:SOXL", "kr:005930", "us:AAPL"])
        XCTAssertTrue(preferences.moveStockSymbol("us:AAPL", onto: "us:SOXL"))
        XCTAssertEqual(preferences.stockSymbols, ["us:AAPL", "us:SOXL", "kr:005930"])
        XCTAssertEqual(preferences.providerOrder, ["claude", "widget-stock:us:AAPL", "system-cpu",
                                                   "widget-stock:us:SOXL", "widget-calendar", "widget-stock:kr:005930"])
        XCTAssertFalse(preferences.moveStockSymbol("us:UNKNOWN", onto: "us:SOXL"))
        XCTAssertEqual(Preferences(defaults: defaults).orderedStocks.map(\.id), preferences.stockSymbols)
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

    private static var calendarPayload = ""
    private static var startedAt: Date?
    private static var delaysQuote = false
    private var responseTask: DispatchWorkItem?
    static var firstRequestAt: Date? { lock.withLock { startedAt } }
    static func reset(calendar: String = "", delayedQuote: Bool = false) {
        lock.withLock { recorded = []; calendarPayload = calendar; startedAt = nil; delaysQuote = delayedQuote }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }

    override func startLoading() {
        let (calendar, delayedQuote) = Self.lock.withLock {
            if Self.startedAt == nil { Self.startedAt = Date() }
            Self.recorded.append(request)
            return (Self.calendarPayload, Self.delaysQuote)
        }
        let data: Data
        if request.url?.path == "/oauth2/token" {
            data = Data(#"{"access_token":"monitor-test-token","expires_in":3600}"#.utf8)
        } else if delayedQuote && request.url?.path == "/api/v1/prices" {
            data = Data(#"{"result":[{"symbol":"SOXL","lastPrice":"144.1","currency":"USD","timestamp":null}]}"#.utf8)
        } else if request.url?.path == "/api/v1/market-calendar/US" {
            data = Data(calendar.utf8)
        } else if request.url?.path == "/api/v1/candles" {
            let count = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "count" })?.value ?? "") ?? 0
            let candles = [
                ["timestamp": "2026-09-25T04:00:00Z", "closePrice": "102"],
                ["timestamp": "2026-09-24T04:00:00Z", "closePrice": "101"],
                ["timestamp": "2026-09-23T04:00:00Z", "closePrice": "100"]
            ]
            data = try! JSONSerialization.data(withJSONObject: ["result": ["candles": Array(candles.prefix(count))]])
        } else {
            let rows: [[String: String]] = (0..<200).map {
                ["symbol": "T\($0)", "lastPrice": "\($0)", "currency": "USD"]
            }
            data = try! JSONSerialization.data(withJSONObject: ["result": rows])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.responseTask?.isCancelled != true else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        responseTask = finish
        DispatchQueue.global().asyncAfter(deadline: .now() + (delayedQuote && request.url?.path == "/api/v1/prices" ? 0.1 : 0), execute: finish)
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

private final class TossTokenEndpoint: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var issues = 0
    private static var rejectsPrice = false
    static var tokenRequests: Int { lock.withLock { issues } }

    static func reset() { lock.withLock { issues = 0; rejectsPrice = false } }
    static func rejectNextPrice() { lock.withLock { rejectsPrice = true } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, payload): (Int, String) = Self.lock.withLock {
            if request.url?.path == "/oauth2/token" {
                Self.issues += 1
                return (200, #"{"access_token":"token-\#(Self.issues)","expires_in":3600}"#)
            }
            if Self.rejectsPrice {
                Self.rejectsPrice = false
                return (401, #"{"error":{"code":"unauthorized"}}"#)
            }
            return (200, #"{"result":[{"symbol":"SOXL","lastPrice":"35.81","currency":"USD"}]}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
