import Foundation

/// Public, adjusted-as-fetched inputs. Target prices are deliberately a separate type.
struct StockBacktestInput: Codable, Equatable {
    struct Close: Codable, Equatable { var date: Int64; var price: Decimal }
    struct Minute: Codable, Equatable {
        var end: Int64
        var open: Decimal
        var high: Decimal
        var low: Decimal
        var close: Decimal
        var volume: Decimal
        var candle: StockCandle {
            StockCandle(end: StockBacktest.date(end), open: open, high: high, low: low, close: close, volume: volume)
        }

    }
    var version: Int
    var caseID: String
    var stockID: String
    var market: String
    var currency: String
    var tradingDay: String
    var sessionStart: Int64
    var sessionEnd: Int64
    var cutoff: Int64
    var inputBarEnd: Int64
    var inputPrice: Decimal
    var previousClose: Decimal
    var priceBasis: String
    var dailyCloses: [Close]
    var minutes: [Minute]

    var trading: TradingSession {
        TradingSession(startTime: StockBacktest.date(sessionStart), endTime: StockBacktest.date(sessionEnd))
    }
    var at: Date { StockBacktest.date(cutoff) }
    var isValid: Bool {
        guard version == 1, let stock = WatchedStock.parse(stockID), stock.id == stockID,
              stock.market.rawValue == market, currency == (market == "kr" ? "KRW" : "USD"),
              !stock.symbol.contains(".."), caseID == "\(market)_\(stock.symbol)_\(tradingDay)",
              priceBasis == StockBacktest.priceBasis,
              [sessionStart, sessionEnd, cutoff, inputBarEnd].allSatisfy(StockBacktest.time),
              sessionEnd - sessionStart > 3_600_000, cutoff == sessionEnd - 3_600_000,
              inputBarEnd <= cutoff, cutoff - inputBarEnd <= 120_000,
              StockBacktest.positive(inputPrice), StockBacktest.positive(previousClose),
              dailyCloses.count <= 61, minutes.count <= 1_400, let last = minutes.last,
              last.end == inputBarEnd, last.close == inputPrice else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockQuoteCodec.timeZone(for: stock.market)
        let day = StockBacktest.day(StockBacktest.date(sessionStart), calendar: calendar)
        guard tradingDay == day,
              StockBacktest.day(StockBacktest.date(sessionEnd - 1), calendar: calendar) == day else { return false }
        let days = dailyCloses.map { calendar.startOfDay(for: StockBacktest.date($0.date)) }
        guard dailyCloses.allSatisfy({ StockBacktest.time($0.date) && StockBacktest.positive($0.price) }),
              dailyCloses.first.map({ $0.price == previousClose }) ?? true,
              days.allSatisfy({ $0 < calendar.startOfDay(for: trading.startTime) }),
              zip(days, days.dropFirst()).allSatisfy({ $0 > $1 }) else { return false }
        return minutes.allSatisfy {
            StockBacktest.time($0.end) && $0.end - 60_000 >= sessionStart && $0.end <= cutoff
                && [$0.open, $0.high, $0.low, $0.close].allSatisfy(StockBacktest.positive)
                && StockBacktest.finite($0.volume) && $0.volume >= 0
                && $0.high >= max($0.open, $0.close) && $0.low <= min($0.open, $0.close)
        } && zip(minutes, minutes.dropFirst()).allSatisfy { $0.end < $1.end }
    }
}

struct StockBacktestCase: Codable, Equatable {
    struct Target: Codable, Equatable { var actualClose: Decimal; var candleAt: Int64; var fetchedAt: Int64 }
    struct Source: Codable, Equatable {
        struct Page: Codable, Equatable {
            var before: String
            var nextBefore: String?
            var fetchedAt: Int64
            func encode(to encoder: Encoder) throws {
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encode(before, forKey: .before)
                try fields.encode(nextBefore, forKey: .nextBefore)
                try fields.encode(fetchedAt, forKey: .fetchedAt)
            }
        }
        var provider: String
        var calendarFetchedAt: Int64
        var dailyFetchedAt: Int64
        var minutePages: [Page]
    }
    var version: Int
    var input: StockBacktestInput
    var target: Target
    var source: Source
    var isValid: Bool {
        guard version == 1, input.isValid, StockBacktest.positive(target.actualClose),
              [target.candleAt, target.fetchedAt, source.calendarFetchedAt, source.dailyFetchedAt]
                .allSatisfy(StockBacktest.time), target.fetchedAt >= input.sessionEnd,
              source.provider == "toss", source.minutePages.count <= 8,
              source.minutePages.allSatisfy({ StockBacktest.cursor($0.before)
                  && ($0.nextBefore.map(StockBacktest.cursor) ?? true) && StockBacktest.time($0.fetchedAt) }) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StockQuoteCodec.timeZone(for: WatchedStock.parse(input.stockID)!.market)
        return StockBacktest.day(StockBacktest.date(target.candleAt), calendar: calendar) == input.tradingDay
    }
}

struct StockBacktestOutcome: Codable, Equatable {
    enum Status: String, Codable { case forecast, skipped }
    struct Forecast: Codable, Equatable {
        let expectedClose: Decimal
        let lowerClose: Decimal
        let upperClose: Decimal
        let riseProbability: Double
        let observations: Int
        init(_ forecast: StockForecast) {
            expectedClose = forecast.expectedClose; lowerClose = forecast.lowerClose; upperClose = forecast.upperClose
            riseProbability = forecast.riseProbability; observations = forecast.observations
        }
    }
    let model: String
    let status: Status
    let reason: String?
    let forecast: Forecast?
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(model, forKey: .model)
        try fields.encode(status, forKey: .status)
        try fields.encode(reason, forKey: .reason)
        try fields.encode(forecast, forKey: .forecast)
    }
}

struct StockBacktestResult: Codable {
    var version: Int
    var caseID: String
    var inputSHA256: String
    var calculationVersion: String
    var computedAt: Int64
    var outcomes: [StockBacktestOutcome]
}

struct StockBacktestManifest: Codable {
    enum Status: String, Codable { case ready, running, paused, completed }
    struct Entry: Codable {
        enum Status: String, Codable { case pending, saved, skipped }
        var caseID: String
        var stockID: String
        var tradingDay: String
        var status: Status
        var inputSHA256: String?
        var resultSHA256: String?
        var reason: String?
        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(caseID, forKey: .caseID)
            try fields.encode(stockID, forKey: .stockID)
            try fields.encode(tradingDay, forKey: .tradingDay)
            try fields.encode(status, forKey: .status)
            try fields.encode(inputSHA256, forKey: .inputSHA256)
            try fields.encode(resultSHA256, forKey: .resultSHA256)
            try fields.encode(reason, forKey: .reason)
        }
    }
    var version: Int
    var runID: UUID
    var createdAt: Int64
    var collectionStartedAt: Int64
    var collectionCompletedAt: Int64?
    var protocolVersion: String
    var codeVersion: String
    var priceBasis: String
    var cutoffMinutes: Int
    var sessions: Int
    var symbols: [String]
    var models: [String]
    var status: Status
    var cases: [Entry]
}

enum StockBacktest {
    static let priceBasis = "provider-adjusted-as-fetched"
    static func predict(input: StockBacktestInput, interval: StockChartInterval) -> StockBacktestOutcome {
        let model = "GBM \(interval == .day ? "daily" : interval.rawValue) zero drift v1 / replay v1"
        guard input.isValid else {
            return StockBacktestOutcome(model: model, status: .skipped, reason: "invalid_input", forecast: nil)
        }
        let forecast: StockForecast?
        if interval == .day {
            forecast = input.dailyCloses.count == 61 ? StockForecast.estimate(price: input.inputPrice,
                completedCloses: input.dailyCloses.map(\.price), trading: input.trading, now: input.at) : nil
        } else {
            forecast = StockForecast.intradayEstimate(price: input.inputPrice, previous: input.previousClose,
                bars: input.minutes.map(\.candle), trading: input.trading, at: input.at, interval: interval)
        }
        return StockBacktestOutcome(model: model, status: forecast == nil ? .skipped : .forecast,
            reason: forecast == nil ? (interval == .day ? "insufficient_daily_history" : "insufficient_intraday_history") : nil,
            forecast: forecast.map(StockBacktestOutcome.Forecast.init))
    }

    /// JSON boundary for later callers; reject unknown fields before Codable can discard them.
    static func decodeCase(_ data: Data) throws -> StockBacktestCase {
        let object = try JSONSerialization.jsonObject(with: data)
        func keys(_ value: Any?, _ names: [String]) throws -> [String: Any] {
            guard let row = value as? [String: Any], Set(row.keys) == Set(names) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return row
        }
        let body = try keys(object, ["version", "input", "target", "source"])
        let input = try keys(body["input"], ["version", "caseID", "stockID", "market", "currency", "tradingDay",
            "sessionStart", "sessionEnd", "cutoff", "inputBarEnd", "inputPrice", "previousClose", "priceBasis", "dailyCloses", "minutes"])
        guard let closes = input["dailyCloses"] as? [Any], let minutes = input["minutes"] as? [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for close in closes { _ = try keys(close, ["date", "price"]) }
        for minute in minutes { _ = try keys(minute, ["end", "open", "high", "low", "close", "volume"]) }
        _ = try keys(body["target"], ["actualClose", "candleAt", "fetchedAt"])
        let source = try keys(body["source"], ["provider", "calendarFetchedAt", "dailyFetchedAt", "minutePages"])
        guard let pages = source["minutePages"] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        for page in pages { _ = try keys(page, ["before", "nextBefore", "fetchedAt"]) }
        let value = try JSONDecoder().decode(StockBacktestCase.self, from: data)
        guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    static func time(_ value: Int64) -> Bool { (0...253_402_300_799_000).contains(value) }
    static func finite(_ price: Decimal) -> Bool { NSDecimalNumber(decimal: price).doubleValue.isFinite }
    static func positive(_ price: Decimal) -> Bool { finite(price) && price > 0 }
    static func cursor(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                         options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: text) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) != nil
    }
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
