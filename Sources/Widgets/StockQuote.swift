import Foundation

/// One symbol the user asked to watch. Korean codes and US tickers share one
/// list, so the market is part of the identity: `005930` is not `AAPL`.
struct WatchedStock: Equatable, Identifiable {
    enum Market: String, Equatable { case kr, us }

    var symbol: String
    var market: Market
    var id: String { "\(market.rawValue):\(symbol)" }

    /// `KR:005930`, `US:BRK.B`, a 6-character code that contains a digit, or a
    /// US ticker. Anything else is refused rather than sent to the wrong book.
    static func parse(_ raw: String) -> WatchedStock? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.isEmpty, text.count <= 20 else { return nil }
        var forced: Market?
        if text.hasPrefix("KR:") {
            forced = .kr
            text = String(text.dropFirst(3))
        } else if text.hasPrefix("US:") {
            forced = .us
            text = String(text.dropFirst(3))
        }
        guard text.range(of: #"^[A-Z0-9][A-Z0-9.\-]{0,14}$"#, options: .regularExpression) != nil else { return nil }
        if let forced {
            return matches(text, market: forced) ? WatchedStock(symbol: text, market: forced) : nil
        }
        if text.count == 6, text.range(of: #"^[0-9A-Z]{6}$"#, options: .regularExpression) != nil,
           text.contains(where: \.isNumber) {
            return WatchedStock(symbol: text, market: .kr)
        }
        guard text.range(of: #"^[A-Z][A-Z0-9.\-]{0,9}$"#, options: .regularExpression) != nil else { return nil }
        return WatchedStock(symbol: text, market: .us)
    }

    private static func matches(_ text: String, market: Market) -> Bool {
        switch market {
        case .kr: return text.range(of: #"^[0-9A-Z]{6}$"#, options: .regularExpression) != nil
        case .us: return text.range(of: #"^[A-Z][A-Z0-9.\-]{0,9}$"#, options: .regularExpression) != nil
        }
    }

    static func parseList(_ stored: [String], limit: Int = 30) -> [WatchedStock] {
        var seen = Set<String>()
        var stocks: [WatchedStock] = []
        for raw in stored {
            guard let stock = parse(raw), seen.insert(stock.id).inserted else { continue }
            stocks.append(stock)
            if stocks.count == limit { break }
        }
        return stocks
    }
}

struct StockTick: Equatable {
    var price: Decimal
    var volume: Decimal?
    var timestamp: Date
    var currency: String
    // Missing provider timestamps use a sentinel, never the receipt time.
    var hasTimestamp = true
}

struct StockQuoteSession: Equatable {
    enum Phase: String { case day, pre, regular, after }
    let phase: Phase
    let tradingDay: Date
    let startTime: Date
    let endTime: Date
    let regularStart: Date
    let regularEnd: Date

    var label: String {
        switch phase {
        case .day: return L10n.t("Day market")
        case .pre: return L10n.t("Pre-market")
        case .regular: return L10n.t("Regular market")
        case .after: return L10n.t("After-hours")
        }
    }
}

struct StockDailyCloses {
    let values: [(date: Date, close: Decimal)]
    // A request crossing the closing bell must not certify an unfinished bar.
    let requestedAt: Date
}

enum StockQuoteSource: String, CaseIterable, Identifiable {
    case toss, finnhub
    var id: String { rawValue }
    var title: String { self == .toss ? "Toss Securities" : "Finnhub" }

    func supports(_ stock: WatchedStock) -> Bool { self == .toss || stock.market == .us }
}

struct StockCandle {
    var end: Date
    var open: Decimal
    var high: Decimal
    var low: Decimal
    var close: Decimal
    var volume: Decimal
}

enum TossSocketEvent {
    case tick(id: String, tick: StockTick)
    case subscribed([String])
    case rejected([(String, String)])
    case pong
    case failure(String)
}

/// Pure decoding for the Toss Securities quote payloads. The socket and the
/// REST current-price call share the same decimal and timestamp rules.
enum StockQuoteCodec {
    static func subscriptionJSON(_ stocks: [WatchedStock]) -> String {
        var items: [[String: Any]] = [["id": "req-1"]]
        let korean = stocks.filter { $0.market == .kr }.map(\.symbol)
        let us = stocks.filter { $0.market == .us }.map(\.symbol)
        if !korean.isEmpty { items.append(["type": "trade:kr", "codes": korean]) }
        if !us.isEmpty { items.append(["type": "trade:us", "codes": us]) }
        let data = try? JSONSerialization.data(withJSONObject: items)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func token(from data: Data) -> (accessToken: String, expiresIn: TimeInterval)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty
        else { return nil }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (token, expires)
    }

    static func prices(from data: Data, requireTimestamp: Bool = false) -> [String: StockTick] {
        guard let rows = rows(in: data) else { return [:] }
        var quotes: [String: StockTick] = [:]
        for row in rows {
            guard let symbol = row["symbol"] as? String,
                  let stock = WatchedStock.parse(symbol),
                  let price = decimal(row["lastPrice"]),
                  let currency = row["currency"] as? String
            else { continue }
            let timestamp = date(row["timestamp"], allowDateOnly: false)
            if requireTimestamp && timestamp == nil { continue }
            quotes[stock.id] = StockTick(price: price, volume: nil,
                                          timestamp: timestamp ?? .distantPast,
                                          currency: currency, hasTimestamp: timestamp != nil)
        }
        return quotes
    }

    static func names(from data: Data) -> [String: String] {
        guard let rows = rows(in: data) else { return [:] }
        var names: [String: String] = [:]
        for row in rows {
            guard let symbol = row["symbol"] as? String, let stock = WatchedStock.parse(symbol) else { continue }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = (row["englishName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { names[stock.id] = name }
            else if let english, !english.isEmpty { names[stock.id] = english }
        }
        return names
    }

    static func event(from text: String) -> TossSocketEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "pong":
            return .pong
        case "subscriptions":
            let subscribed = object["subscribed"] as? [String] ?? []
            let rejected = (object["rejected"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
                let topic = (item["topic"] as? String) ?? (item["symbol"] as? String) ?? ""
                guard !topic.isEmpty else { return nil }
                return (topic, item["code"] as? String ?? "rejected")
            }
            return rejected.isEmpty ? .subscribed(subscribed) : .rejected(rejected)
        case "message":
            guard let topic = object["topic"] as? String,
                  let payload = object["data"] as? [String: Any],
                  let price = decimal(payload["price"]),
                  let currency = payload["currency"] as? String,
                  let stock = stock(fromTopic: topic)
            else { return nil }
            let timestamp = date(payload["timestamp"], allowDateOnly: false)
            let tick = StockTick(price: price, volume: decimal(payload["volume"]),
                                 timestamp: timestamp ?? .distantPast,
                                 currency: currency, hasTimestamp: timestamp != nil)
            return .tick(id: stock.id, tick: tick)
        case "error":
            let error = object["error"] as? [String: Any]
            return .failure(error?["code"] as? String ?? "error")
        default:
            return nil
        }
    }

    static func stock(fromTopic topic: String) -> WatchedStock? {
        for market in [WatchedStock.Market.kr, .us] {
            let prefix = "trade:\(market.rawValue):"
            guard topic.hasPrefix(prefix) else { continue }
            return WatchedStock.parse("\(market.rawValue.uppercased()):\(topic.dropFirst(prefix.count))")
        }
        return nil
    }

    static func format(price: Decimal, currency: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.roundingMode = .halfUp
        if currency == "KRW" {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        let number = NSDecimalNumber(decimal: price)
        let text = formatter.string(from: number) ?? "\(price)"
        return currency == "USD" ? "$\(text)" : text
    }

    static func clock(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jms")
        return formatter.string(from: date)
    }

    /// A move of this size fills the ring. Thirty percent is the Korean daily
    /// limit, so a limit-up or limit-down is a complete circle.
    static let fullRingChange = Decimal(string: "0.30")!

    static func changeRate(price: Decimal, previousClose: Decimal) -> Decimal? {
        guard previousClose != 0 else { return nil }
        return (price - previousClose) / previousClose
    }

    static func ringFraction(for changeRate: Decimal) -> Double {
        let magnitude = changeRate < 0 ? -changeRate : changeRate
        let scaled = NSDecimalNumber(decimal: magnitude / fullRingChange).doubleValue
        guard scaled.isFinite else { return 0 }
        return min(max(scaled, 0), 1)
    }

    static func formatChange(_ rate: Decimal, locale: Locale,
                             roundingMode: NumberFormatter.RoundingMode? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        if let roundingMode { formatter.roundingMode = roundingMode }
        formatter.positivePrefix = formatter.plusSign
        formatter.negativePrefix = formatter.minusSign
        let text = formatter.string(from: NSDecimalNumber(decimal: rate * 100)) ?? "0.00"
        return text + "%"
    }

    static func timeZone(for market: WatchedStock.Market) -> TimeZone {
        switch market {
        case .kr: return TimeZone(identifier: "Asia/Seoul") ?? .gmt
        case .us: return TimeZone(identifier: "America/New_York") ?? .gmt
        }
    }

    static func marketDate(_ date: Date, market: WatchedStock.Market, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone(for: market)
        formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// REST snapshots can arrive after a newer socket trade. Neither older
    /// nor future trades may replace it, and an undated price cannot date it.
    static func accepts(_ tick: StockTick, replacing old: StockTick?, now: Date) -> Bool {
        if !tick.hasTimestamp { return old?.hasTimestamp != true }
        guard tick.timestamp.timeIntervalSince1970.isFinite, tick.timestamp <= now else { return false }
        if let old, old.hasTimestamp { return tick.timestamp >= old.timestamp }
        return true
    }

    static func usSession(at timestamp: Date, calendar: MarketSessions?) -> StockQuoteSession? {
        guard timestamp.timeIntervalSince1970.isFinite, let calendar else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone(for: .us)
        var match: StockQuoteSession?
        for day in [calendar.previousBusinessDay, calendar.today, calendar.nextBusinessDay].compactMap({ $0 }) {
            guard let regular = day.regularMarket, regular.duration.isFinite, regular.duration > 0 else { continue }
            let phases: [(StockQuoteSession.Phase, TradingSession?)] = [
                (.day, day.dayMarket), (.pre, day.preMarket), (.regular, regular), (.after, day.afterMarket)
            ]
            for (phase, session) in phases {
                guard let session, session.duration.isFinite, session.contains(timestamp) else { continue }
                switch phase {
                case .day, .pre: guard session.endTime <= regular.startTime else { continue }
                case .after: guard session.startTime >= regular.endTime else { continue }
                case .regular: break
                }
                let candidate = StockQuoteSession(phase: phase, tradingDay: local.startOfDay(for: regular.startTime),
                    startTime: session.startTime, endTime: session.endTime,
                    regularStart: regular.startTime, regularEnd: regular.endTime)
                if let match, match != candidate { return nil }
                match = candidate
            }
        }
        return match
    }

    static func changeBasis(daily: StockDailyCloses?, quote: StockTick, market: WatchedStock.Market,
                            session: StockQuoteSession?) -> (date: Date, close: Decimal)? {
        guard quote.hasTimestamp, let daily else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(for: market)
        let tradingDay: Date
        if market == .us {
            guard let session, session.startTime <= quote.timestamp, quote.timestamp < session.endTime,
                  daily.requestedAt >= session.startTime else { return nil }
            tradingDay = session.tradingDay
            if session.phase == .after {
                guard daily.requestedAt >= session.regularEnd else { return nil }
                // US DAILY candles contain only regular trading. Never fall
                // back to the preceding day for an after-hours percentage.
                return daily.values.first { calendar.isDate($0.date, inSameDayAs: tradingDay) && $0.close > 0 }
            }
        } else {
            tradingDay = calendar.startOfDay(for: quote.timestamp)
        }
        return daily.values.filter { calendar.startOfDay(for: $0.date) < tradingDay && $0.close > 0 }
            .max { $0.date < $1.date }
    }

    /// Daily candles are newest first. The close before the session that owns
    /// `priceTime` is the previous close. A new day with no candle yet uses
    /// the newest close, which is that previous session.
    static func previousClose(closes: [(date: Date, close: Decimal)], priceTime: Date,
                              timeZone: TimeZone) -> Decimal? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let priceDay = calendar.startOfDay(for: priceTime)
        return closes.filter { calendar.startOfDay(for: $0.date) < priceDay }
            .max { $0.date < $1.date }?.close
    }

    static func dailyCloses(from data: Data) -> [(date: Date, close: Decimal)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let candles = result["candles"] as? [[String: Any]]
        else { return [] }
        return candles.compactMap { row in
            guard let close = decimal(row["closePrice"]), let date = date(row["timestamp"]) else { return nil }
            return (date, close)
        }
    }

    static func candles(from data: Data) -> [StockCandle]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rows = result["candles"] as? [[String: Any]] else { return nil }
        let candles = rows.compactMap { row -> StockCandle? in
            guard let end = date(row["timestamp"]),
                  let open = decimal(row["openPrice"]), let high = decimal(row["highPrice"]),
                  let low = decimal(row["lowPrice"]), let close = decimal(row["closePrice"]),
                  let volume = decimal(row["volume"])
            else { return nil }
            return StockCandle(end: end, open: open, high: high, low: low,
                               close: close, volume: volume)
        }
        guard candles.count == rows.count else { return nil }
        return candles
    }

    static let movingAveragePeriods = [5, 20, 60, 120]

    /// One trailing average per input bar. Warm-up entries stay nil; future bars never enter a window.
    static func movingAverages(for candles: [StockCandle], period: Int) -> [Double?] {
        var values = [Double?](repeating: nil, count: candles.count)
        let closes = candles.map { NSDecimalNumber(decimal: $0.close).doubleValue }
        guard period > 0, closes.allSatisfy({ $0.isFinite && $0 > 0 }),
              candles.allSatisfy({ $0.end.timeIntervalSince1970.isFinite }),
              zip(candles, candles.dropFirst()).allSatisfy({ $0.end < $1.end }) else { return values }
        var sum = 0.0
        for index in closes.indices {
            sum += closes[index]
            if index >= period { sum -= closes[index - period] }
            if index >= period - 1, sum.isFinite { values[index] = sum / Double(period) }
        }
        return values
    }

    /// The API's minute timestamp marks the *end* of [minute - 1, minute).
    /// Subtract a second so 09:10 joins 09:01–09:09, not 09:11–09:20.
    static func tenMinuteCandles(from minutes: [StockCandle]) -> [StockCandle] {
        var result: [StockCandle] = []
        for minute in minutes.sorted(by: { $0.end < $1.end }) {
            let end = Date(timeIntervalSince1970: floor((minute.end.timeIntervalSince1970 - 1) / 600) * 600 + 600)
            if let last = result.indices.last, result[last].end == end {
                result[last].high = max(result[last].high, minute.high)
                result[last].low = min(result[last].low, minute.low)
                result[last].close = minute.close
                result[last].volume += minute.volume
            } else {
                var candle = minute
                candle.end = end
                result.append(candle)
            }
        }
        return result
    }

    /// Forecasts intentionally use only the current regular session.
    static func completedRegularBars(_ minutes: [StockCandle], trading: TradingSession,
                                     through: Date, interval: StockChartInterval) -> [StockCandle] {
        let regular = minutes.filter {
            $0.end > trading.startTime && $0.end <= trading.endTime
                && $0.end.addingTimeInterval(-60) >= trading.startTime
        }
        return completedIntradayBars(regular, through: through, interval: interval)
    }

    /// Historical analysis also uses earlier trading days and extended-hours bars.
    static func completedIntradayBars(_ minutes: [StockCandle], through: Date,
                                      interval: StockChartInterval) -> [StockCandle] {
        let completed = minutes.filter {
            $0.end <= through && $0.open > 0 && $0.close > 0
                && NSDecimalNumber(decimal: $0.close).doubleValue.isFinite
        }.sorted { $0.end < $1.end }
        guard Set(completed.map(\.end)).count == completed.count else { return [] }
        var bars = completed
        if interval == .tenMinutes {
            // The chart may draw partial buckets. Analysis requires all ten one-minute bars.
            bars = StockQuoteCodec.tenMinuteCandles(from: completed).filter { bar in
                let group = completed.filter { $0.end > bar.end.addingTimeInterval(-600) && $0.end <= bar.end }
                return group.count == 10 && group.enumerated().allSatisfy { index, minute in
                    abs(minute.end.timeIntervalSince(bar.end) + Double(9 - index) * 60) < 0.01
                }
            }
        }
        return bars
    }

    private static func rows(in data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["result"] as? [[String: Any]]
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let text as String:
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        case let number as NSNumber:
            return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        default:
            return nil
        }
    }

    private static func date(_ value: Any?, allowDateOnly: Bool = true) -> Date? {
        guard let text = value as? String else { return nil }
        if !allowDateOnly {
            guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                             options: .regularExpression) != nil else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        guard allowDateOnly else { return nil }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "Asia/Seoul")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: text)
    }
}

/// How every notch cell draws its reading. Stocks keep the 30 percent scale
/// and the green or red direction in both styles.
enum NotchMeterStyle: String, CaseIterable, Identifiable {
    case ring
    case bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: return L10n.t("Circles")
        case .bar: return L10n.t("Bars")
        }
    }
}

enum StockLink: Equatable {
    case idle
    case live
    case reconnecting
    case failed(String)
}

/// One notch circle per registered symbol. The arc is the move from the
/// previous close, and thirty percent fills it.
enum StockBoard {
    static let snapshotID = "widget-stocks"

    static func cellID(_ stock: WatchedStock) -> String { "widget-stock:\(stock.id)" }

    static func snapshot(stock: WatchedStock, quote: StockTick?, previousClose: Decimal?, name: String?,
                         link: StockLink, locale: Locale = L10n.locale,
                         source: StockQuoteSource = .toss, quoteSession: StockQuoteSession? = nil,
                         basisDate: Date? = nil) -> ProviderSnapshot {
        let provider = source.title
        let title = (stock.market == .kr ? KoreanStockDirectory.shared.name(for: stock.symbol) : nil)
            ?? name?.precomposedStringWithCanonicalMapping ?? stock.symbol
        let label = stock.market == .kr ? title : stock.symbol
        guard let quote else {
            return ProviderSnapshot(id: cellID(stock), displayName: title, glyph: .stock, fidelity: .official,
                                    status: .unsupported(emptyMessage(link)), windows: [], kind: .stocks,
                                    ringLabel: label, plan: provider)
        }
        let tossUS = source == .toss && stock.market == .us
        let previousClose = quote.hasTimestamp && (!tossUS || quoteSession != nil) ? previousClose : nil
        let changeLabel = tossUS
            ? L10n.t(quoteSession?.phase == .after ? "Change vs same-day regular close" : "Change vs previous regular close")
            : L10n.t("Change")
        let priceText = StockQuoteCodec.format(price: quote.price, currency: quote.currency, locale: locale)
        var windows: [LimitWindow] = []
        if let previousClose,
           let rate = StockQuoteCodec.changeRate(price: quote.price, previousClose: previousClose) {
            let percent = StockQuoteCodec.formatChange(rate, locale: locale,
                                                       roundingMode: source == .toss ? .down : nil)
            let band: UsageBand? = rate > 0 ? .ample : (rate < 0 ? .critical : nil)
            windows.append(LimitWindow(id: "change", label: changeLabel,
                                       usedFraction: StockQuoteCodec.ringFraction(for: rate),
                                       usedText: percent,
                                       detail: percent,
                                       bandOverride: band, prefersUsedText: true))
            let basisPrice = StockQuoteCodec.format(price: previousClose, currency: quote.currency, locale: locale)
            let basisText = basisDate.map { "\(StockQuoteCodec.marketDate($0, market: stock.market)) · \(basisPrice)" } ?? basisPrice
            windows.append(LimitWindow(id: "previous", label: tossUS ? L10n.t("Regular close basis") : L10n.t("Previous close"),
                                       detail: basisText))
        } else {
            windows.append(LimitWindow(id: "change", label: changeLabel,
                                       usedText: "—", detail: L10n.t("Previous close unavailable"),
                                       prefersUsedText: true))
        }
        windows.append(LimitWindow(id: "price", label: L10n.t("Last price"),
                                   usedText: priceText, detail: priceText, prefersUsedText: true))
        if tossUS {
            let context = quoteSession.map { "\($0.label) · \(StockQuoteCodec.marketDate($0.tradingDay, market: .us)) ET" }
                ?? L10n.t("Session unavailable")
            windows.append(LimitWindow(id: "session", label: L10n.t("US session"), detail: context))
        }
        let traded = tossUS ? "\(StockQuoteCodec.marketDate(quote.timestamp, market: .us, includeTime: true)) ET"
            : StockQuoteCodec.clock(quote.timestamp, locale: locale)
        windows.append(LimitWindow(id: "traded", label: L10n.t("Last trade"),
                                   detail: quote.hasTimestamp ? "\(quote.currency) · \(traded)" : L10n.t("Trade time unavailable")))
        if link != .live {
            windows.append(LimitWindow(id: "link", label: L10n.t("Connection"), detail: linkText(link, source: source)))
        }
        return ProviderSnapshot(id: cellID(stock), displayName: title, glyph: .stock, fidelity: .official,
                                status: .ok, windows: windows,
                                headlineID: previousClose == nil && (tossUS || !quote.hasTimestamp) ? "price" : "change", kind: .stocks,
                                ringLabel: label, plan: provider)
    }

    static func displayText(for snapshot: ProviderSnapshot, at date: Date,
                            since start: Date, interval: Int) -> String {
        guard interval > 0,
              let change = snapshot.windows.first(where: { $0.id == "change" })?.usedText,
              change != "—",
              let price = snapshot.windows.first(where: { $0.id == "price" })?.usedText else {
            return snapshot.headlineText
        }
        let phase = Int(max(0, date.timeIntervalSince(start)) / Double(interval))
        return phase.isMultiple(of: 2) ? change : price
    }

    static func orderSnapshots(stored: [String]) -> [ProviderSnapshot] {
        let stocks = WatchedStock.parseList(stored)
        if stocks.isEmpty { return [placeholder(message: "")] }
        return stocks.map { snapshot(stock: $0, quote: nil, previousClose: nil, name: nil, link: .idle) }
    }

    static func placeholder(message: String, source: StockQuoteSource = .toss) -> ProviderSnapshot {
        ProviderSnapshot(id: snapshotID, displayName: L10n.t("Stocks"), glyph: .stock, fidelity: .official,
                         status: .unsupported(message), windows: [], kind: .stocks, plan: source.title)
    }

    private static func emptyMessage(_ link: StockLink) -> String {
        if case .failed(let message) = link { return message }
        return L10n.t("Waiting for the next trade.")
    }

    private static func linkText(_ link: StockLink, source: StockQuoteSource) -> String {
        switch link {
        case .idle: return source == .finnhub ? L10n.t("Connecting to Finnhub…") : L10n.t("Connecting to Toss Securities…")
        case .live: return L10n.t("Live")
        case .reconnecting: return L10n.t("Reconnecting…")
        case .failed(let message): return message
        }
    }
}
