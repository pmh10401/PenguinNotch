import Combine
import Foundation
import CryptoKit
import Darwin

/// Public, adjusted-as-fetched inputs. Target prices are deliberately a separate type.
struct StockBacktestInput: Codable, Equatable, Sendable {
    struct Close: Codable, Equatable, Sendable { var date: Int64; var price: Decimal }
    struct Minute: Codable, Equatable, Sendable {
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

struct StockBacktestCase: Codable, Equatable, Sendable {
    struct Target: Codable, Equatable, Sendable { var actualClose: Decimal; var candleAt: Int64; var fetchedAt: Int64 }
    struct Source: Codable, Equatable, Sendable {
        struct Page: Codable, Equatable, Sendable {
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

struct StockBacktestManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ready, running, paused, completed }
    struct Entry: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case pending, saved, skipped }
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
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(runID, forKey: .runID)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(collectionStartedAt, forKey: .collectionStartedAt)
        try c.encode(collectionCompletedAt, forKey: .collectionCompletedAt)
        try c.encode(protocolVersion, forKey: .protocolVersion); try c.encode(codeVersion, forKey: .codeVersion)
        try c.encode(priceBasis, forKey: .priceBasis); try c.encode(cutoffMinutes, forKey: .cutoffMinutes)
        try c.encode(sessions, forKey: .sessions); try c.encode(symbols, forKey: .symbols)
        try c.encode(models, forKey: .models); try c.encode(status, forKey: .status); try c.encode(cases, forKey: .cases)
    }
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

    static func keys(_ value: Any?, _ names: [String]) throws -> [String: Any] {
        guard let row = value as? [String: Any], Set(row.keys) == Set(names) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return row
    }
    /// Key-only scan before lossy Foundation parsing; stdlib still validates the JSON grammar.
    static func jsonObject(_ data: Data) throws -> Any {
        guard data.count <= 2 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let bytes = Array(data)
        var stack: [(opening: UInt8, keys: Set<String>)] = [], i = 0
        let decoder = JSONDecoder()
        while i < bytes.count {
            switch bytes[i] {
            case 123, 91: // object / array
                guard stack.count < 512 else { throw CocoaError(.fileReadCorruptFile) }
                stack.append((bytes[i], [])); i += 1
            case 125, 93:
                guard let frame = stack.popLast(), frame.opening == (bytes[i] == 125 ? 123 : 91) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                i += 1
            case 34:
                let start = i; i += 1
                while i < bytes.count, bytes[i] != 34 { i += bytes[i] == 92 ? 2 : 1 }
                guard i < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                i += 1
                var next = i
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard stack.last?.opening == 123 else { throw CocoaError(.fileReadCorruptFile) }
                    let key = try decoder.decode(String.self, from: Data(bytes[start..<i]))
                    guard stack[stack.count - 1].keys.insert(key).inserted else { throw CocoaError(.fileReadCorruptFile) }
                }
            default: i += 1
            }
        }
        guard stack.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONSerialization.jsonObject(with: data)
    }
    /// JSON boundary for later callers; reject unknown fields before Codable can discard them.
    static func decodeCase(_ data: Data) throws -> StockBacktestCase {
        let object = try jsonObject(data)
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
        let civil = DateFormatter()
        civil.locale = Locale(identifier: "en_US_POSIX"); civil.timeZone = TimeZone(secondsFromGMT: 0)
        civil.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; civil.isLenient = false
        let prefix = String(text.prefix(19))
        guard let civilDate = civil.date(from: prefix), civil.string(from: civilDate) == prefix else { return false }
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

/// Separate immutable replay files. All filesystem operations are relative to no-follow directory handles.
struct StockBacktestArchive: Sendable {
    let directory: URL
    var fault: (@Sendable (String) throws -> Void)? = nil // Internal fault injection for temp-only preservation tests.
    private static let limit = 2 * 1024 * 1024
    static let models = ["GBM daily zero drift v1 / replay v1", "GBM 1m zero drift v1 / replay v1", "GBM 10m zero drift v1 / replay v1"]
    private static func invalid() -> CocoaError { CocoaError(.fileReadCorruptFile) }
    static func hash(_ body: Data) -> String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    private static func digest(_ text: String?) -> Bool {
        text.map { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil } ?? true
    }
    private static func identity(_ id: String, stockID: String, day: String) -> Bool {
        guard let stock = WatchedStock.parse(stockID), stock.id == stockID, !stock.symbol.contains(".."),
              id == "\(stock.market.rawValue)_\(stock.symbol)_\(day)", safeCaseID(id) else { return false }
        return true
    }
    static func safeCaseID(_ id: String) -> Bool {
        guard !id.contains(".."), id.range(of: #"^(us_[A-Z][A-Z0-9.\-]{0,9}|kr_[A-Z0-9]{6})_\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression) != nil else { return false }
        let day = String(id.suffix(10)), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
    }
    static func decodeManifest(_ body: Data) throws -> StockBacktestManifest {
        let row = try StockBacktest.keys(StockBacktest.jsonObject(body), ["version", "runID", "createdAt", "collectionStartedAt", "collectionCompletedAt",
            "protocolVersion", "codeVersion", "priceBasis", "cutoffMinutes", "sessions", "symbols", "models", "status", "cases"])
        guard let entries = row["cases"] as? [Any] else { throw invalid() }
        for entry in entries { _ = try StockBacktest.keys(entry, ["caseID", "stockID", "tradingDay", "status", "inputSHA256", "resultSHA256", "reason"]) }
        let m = try JSONDecoder().decode(StockBacktestManifest.self, from: body)
        guard m.version == 1, m.protocolVersion == "replay-v1", m.priceBasis == StockBacktest.priceBasis,
              m.cutoffMinutes == 60, [20, 60, 120].contains(m.sessions),
              StockBacktest.time(m.createdAt), StockBacktest.time(m.collectionStartedAt), m.createdAt <= m.collectionStartedAt,
              m.collectionCompletedAt.map({ StockBacktest.time($0) && $0 >= m.collectionStartedAt }) ?? true,
              !m.codeVersion.isEmpty, m.codeVersion.utf8.count <= 128,
              !m.symbols.isEmpty, m.symbols.count <= 30, Set(m.symbols).count == m.symbols.count,
              m.symbols.allSatisfy({ WatchedStock.parse($0)?.id == $0 && !$0.contains("..") }),
              !m.models.isEmpty, Set(m.models).count == m.models.count, m.models.allSatisfy(models.contains),
              m.cases.count <= m.symbols.count * m.sessions, Set(m.cases.map(\.caseID)).count == m.cases.count,
              (m.status == .completed) == (m.collectionCompletedAt != nil) else { throw invalid() }
        var daysByMarket: [String: Set<String>] = [:]
        for e in m.cases {
            guard identity(e.caseID, stockID: e.stockID, day: e.tradingDay), m.symbols.contains(e.stockID),
                  digest(e.inputSHA256), digest(e.resultSHA256), e.reason.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw invalid() }
            let market = WatchedStock.parse(e.stockID)!.market.rawValue // Identity above validates canonical stockID.
            daysByMarket[market, default: []].insert(e.tradingDay)
            guard daysByMarket[market]!.count <= m.sessions else { throw invalid() }
            switch e.status {
            case .pending: guard e.inputSHA256 == nil, e.resultSHA256 == nil, e.reason == nil else { throw invalid() }
            case .saved: guard e.inputSHA256 != nil, e.reason == nil else { throw invalid() }
            case .skipped: guard e.inputSHA256 == nil, e.resultSHA256 == nil, e.reason != nil else { throw invalid() }
            }
        }
        guard m.status != .completed || m.cases.allSatisfy({ $0.status != .pending }) else { throw invalid() }
        return m
    }
    static func decodeResult(_ body: Data) throws -> StockBacktestResult {
        let row = try StockBacktest.keys(StockBacktest.jsonObject(body), ["version", "caseID", "inputSHA256", "calculationVersion", "computedAt", "outcomes"])
        guard let outcomes = row["outcomes"] as? [Any] else { throw invalid() }
        for value in outcomes {
            let outcome = try StockBacktest.keys(value, ["model", "status", "reason", "forecast"])
            if !(outcome["forecast"] is NSNull) {
                _ = try StockBacktest.keys(outcome["forecast"], ["expectedClose", "lowerClose", "upperClose", "riseProbability", "observations"])
            }
        }
        let result = try JSONDecoder().decode(StockBacktestResult.self, from: body)
        guard result.version == 1, safeCaseID(result.caseID), digest(result.inputSHA256),
              result.calculationVersion == "replay-v1", StockBacktest.time(result.computedAt),
              !result.outcomes.isEmpty, result.outcomes.count <= 3,
              Set(result.outcomes.map(\.model)).count == result.outcomes.count else { throw invalid() }
        for o in result.outcomes {
            guard models.contains(o.model) else { throw invalid() }
            if o.status == .forecast {
                guard o.reason == nil, let f = o.forecast,
                      [f.expectedClose, f.lowerClose, f.upperClose].allSatisfy(StockBacktest.positive),
                      f.lowerClose <= f.expectedClose, f.expectedClose <= f.upperClose,
                      f.riseProbability.isFinite, (0...1).contains(f.riseProbability),
                      (10...1_399).contains(f.observations), !o.model.contains("daily") || f.observations == 60 else { throw invalid() }
            } else {
                guard o.forecast == nil, o.reason == (o.model.contains("daily") ? "insufficient_daily_history" : "insufficient_intraday_history") else { throw invalid() }
            }
        }
        return result
    }
    private func encoded(_ m: StockBacktestManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(m); _ = try Self.decodeManifest(body); return body
    }

    // ponytail: serialize this small archive using the OS file lock; per-run locks if throughput matters.
    private func locked<T>(create: Bool = false, _ operation: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw Self.invalid() }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.invalid() }
        defer { Darwin.close(fd) }
        for part in directory.pathComponents.dropFirst() {
            if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw Self.invalid() }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.invalid() }
            Darwin.close(fd); fd = next
        }
        guard flock(fd, LOCK_EX) == 0 else { throw Self.invalid() }
        defer { flock(fd, LOCK_UN) }
        return try operation(fd)
    }
    private func folder(_ parent: Int32, _ name: String, create: Bool = false) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw Self.invalid() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.invalid() }; return fd
    }
    private func names(_ fd: Int32) throws -> [String] {
        // fdopendir consumes its descriptor; a separate open avoids sharing the directory offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; throw Self.invalid() }
        defer { closedir(dir) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                guard errno == 0 else { throw Self.invalid() }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }
    private func read(_ dir: Int32, _ name: String) throws -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.invalid() }; defer { Darwin.close(fd) }
        try fault?("read:" + name)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.limit else { throw Self.invalid() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Self.invalid() }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count)); guard body.count <= Self.limit else { throw Self.invalid() }
        }
        return body
    }
    private func write(_ dir: Int32, _ name: String, body: Data, replace: Bool = false) throws {
        guard body.count <= Self.limit else { throw Self.invalid() }
        if let old = try read(dir, name), !replace {
            guard old == body else { throw Self.invalid() }; return
        }
        try fault?("write")
        let temp = ".tmp-" + UUID().uuidString
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.invalid() }
        defer { Darwin.close(fd); unlinkat(dir, temp, 0) }
        try body.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw Self.invalid() }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw Self.invalid() }
        try fault?("place")
        if replace {
            guard renameat(dir, temp, dir, name) == 0 else { throw Self.invalid() }
        } else {
            guard renameatx_np(dir, temp, dir, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.invalid() }
        }
        guard fsync(dir) == 0 else { throw Self.invalid() }
    }
    private typealias Inventory = (cases: [String: String], results: [String: String])
    private func withManifest<T>(_ root: Int32, _ id: UUID, _ operation: (Int32, StockBacktestManifest) throws -> T) throws -> T {
        let dir = try folder(root, id.uuidString.lowercased()); defer { Darwin.close(dir) }
        guard let body = try read(dir, "manifest.json") else { throw Self.invalid() }
        let m = try Self.decodeManifest(body); guard m.runID == id else { throw Self.invalid() }
        return try operation(dir, m)
    }
    private func run<T>(_ root: Int32, _ id: UUID, _ operation: (Int32, StockBacktestManifest, Inventory) throws -> T) throws -> T {
        try withManifest(root, id) { dir, m in try operation(dir, m, integrity(dir, m)) }
    }
    private func caseHash(_ body: Data, _ e: StockBacktestManifest.Entry) throws -> String {
        let c = try StockBacktest.decodeCase(body), hash = Self.hash(body)
        guard e.status != .skipped, c.input.caseID == e.caseID, c.input.stockID == e.stockID,
              c.input.tradingDay == e.tradingDay, e.inputSHA256 == nil || e.inputSHA256 == hash else { throw Self.invalid() }
        return hash
    }
    private func resultHash(_ body: Data, _ e: StockBacktestManifest.Entry, inputHash: String, models: [String]) throws -> String {
        let r = try Self.decodeResult(body), hash = Self.hash(body)
        guard e.status != .skipped, r.caseID == e.caseID, r.inputSHA256 == inputHash,
              Set(r.outcomes.map(\.model)) == Set(models),
              e.resultSHA256 == nil || e.resultSHA256 == hash else { throw Self.invalid() }
        return hash
    }
    private func checkHashes(_ m: StockBacktestManifest, _ inventory: Inventory) throws {
        for e in m.cases {
            if let h = e.inputSHA256, h != inventory.cases[e.caseID] { throw Self.invalid() }
            if let h = e.resultSHA256, h != inventory.results[e.caseID] { throw Self.invalid() }
            if e.status == .skipped, inventory.cases[e.caseID] != nil || inventory.results[e.caseID] != nil { throw Self.invalid() }
        }
    }
    private func integrity(_ dir: Int32, _ m: StockBacktestManifest) throws -> Inventory {
        for name in try names(dir) {
            guard ["manifest.json", "cases", "results"].contains(name) || name.hasPrefix(".tmp-") else { throw Self.invalid() }
            if name.hasPrefix(".tmp-") { _ = try read(dir, name) }
        }
        var caseHashes: [String: String] = [:], resultHashes: [String: String] = [:]
        let entries = Dictionary(uniqueKeysWithValues: m.cases.map { ($0.caseID, $0) })
        for kind in ["cases", "results"] {
            let sub = try folder(dir, kind); defer { Darwin.close(sub) }
            for name in try names(sub) {
                guard let body = try read(sub, name) else { throw Self.invalid() }
                if name.hasPrefix(".tmp-") { continue } // Crash leftovers are preserved, never used as evidence.
                guard name.hasSuffix(".json") else { throw Self.invalid() }
                let id = String(name.dropLast(5))
                guard let entry = entries[id] else { throw Self.invalid() }
                if kind == "cases" {
                    caseHashes[id] = try caseHash(body, entry)
                } else {
                    guard let inputHash = caseHashes[id] else { throw Self.invalid() }
                    resultHashes[id] = try resultHash(body, entry, inputHash: inputHash, models: m.models)
                }
            }
        }
        let inventory = (cases: caseHashes, results: resultHashes)
        try checkHashes(m, inventory); return inventory
    }
    func list() throws -> [StockBacktestManifest] {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Self.invalid() }; return []
        }
        return try locked { root in
            try names(root).map { name in
                guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { throw Self.invalid() }
                return try run(root, id) { _, m, _ in m }
            }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    func create(_ manifest: StockBacktestManifest) throws {
        let body = try encoded(manifest)
        try locked(create: true) { root in
            let id = manifest.runID.uuidString.lowercased()
            if try names(root).contains(id) {
                try run(root, manifest.runID) { _, old, _ in guard old == manifest else { throw Self.invalid() } }; return
            }
            guard manifest.status == .ready, manifest.cases.allSatisfy({ $0.status == .pending }) else { throw Self.invalid() }
            let dir = try folder(root, id, create: true); defer { Darwin.close(dir) }
            for name in ["cases", "results"] { Darwin.close(try folder(dir, name, create: true)) }
            try write(dir, "manifest.json", body: body); guard fsync(root) == 0 else { throw Self.invalid() }
        }
    }
    // One off-actor inventory audit also identifies valid orphan case bytes for zero-query resume.
    func collection(runID: UUID) throws -> (manifest: StockBacktestManifest, saved: [String: String]) {
        try locked { root in try run(root, runID) { _, m, inventory in (m, inventory.cases) } }
    }
    func loadManifest(runID: UUID) throws -> StockBacktestManifest {
        try locked { root in try run(root, runID) { _, m, _ in m } }
    }
    func saveCase(runID: UUID, body: Data) throws -> String {
        let c = try StockBacktest.decodeCase(body)
        return try locked { root in try run(root, runID) { dir, m, _ in
            guard let e = m.cases.first(where: { $0.caseID == c.input.caseID }), e.status != .skipped,
                  e.stockID == c.input.stockID, e.tradingDay == c.input.tradingDay else { throw Self.invalid() }
            let sub = try folder(dir, "cases"); defer { Darwin.close(sub) }
            if m.status == .completed, try read(sub, c.input.caseID + ".json") != body { throw Self.invalid() }
            try write(sub, c.input.caseID + ".json", body: body); return Self.hash(body)
        } }
    }
    func loadCase(runID: UUID, caseID: String) throws -> (body: Data, sha256: String) {
        guard Self.safeCaseID(caseID) else { throw Self.invalid() }
        // Selected reads bind strict manifest identity and selected bytes; resume/writes still audit every payload.
        return try locked { root in try withManifest(root, runID) { dir, m in
            guard let e = m.cases.first(where: { $0.caseID == caseID }) else { throw Self.invalid() }
            let sub = try folder(dir, "cases"); defer { Darwin.close(sub) }
            guard let body = try read(sub, caseID + ".json") else { throw Self.invalid() }
            return (body, try caseHash(body, e))
        } }
    }
    func saveResult(runID: UUID, body: Data) throws -> String {
        let r = try Self.decodeResult(body)
        return try locked { root in try run(root, runID) { dir, m, _ in
            guard m.cases.contains(where: { $0.caseID == r.caseID && $0.status != .skipped }), Set(r.outcomes.map(\.model)) == Set(m.models) else { throw Self.invalid() }
            let cases = try folder(dir, "cases"); defer { Darwin.close(cases) }
            guard let input = try read(cases, r.caseID + ".json"), Self.hash(input) == r.inputSHA256 else { throw Self.invalid() }
            let sub = try folder(dir, "results"); defer { Darwin.close(sub) }
            if m.status == .completed, try read(sub, r.caseID + ".json") != body { throw Self.invalid() }
            try write(sub, r.caseID + ".json", body: body); return Self.hash(body)
        } }
    }
    func loadResult(runID: UUID, caseID: String) throws -> Data? {
        guard Self.safeCaseID(caseID) else { throw Self.invalid() }
        return try locked { root in try withManifest(root, runID) { dir, m in
            guard let e = m.cases.first(where: { $0.caseID == caseID }) else { throw Self.invalid() }
            let sub = try folder(dir, "results"); defer { Darwin.close(sub) }
            guard let body = try read(sub, caseID + ".json") else {
                guard e.resultSHA256 == nil else { throw Self.invalid() }; return nil
            }
            let cases = try folder(dir, "cases"); defer { Darwin.close(cases) }
            guard let input = try read(cases, caseID + ".json") else { throw Self.invalid() }
            _ = try resultHash(body, e, inputHash: caseHash(input, e), models: m.models)
            return body
        } }
    }
    func updateProgress(runID: UUID, entries: [StockBacktestManifest.Entry], status: StockBacktestManifest.Status) throws {
        try locked { root in try run(root, runID) { dir, old, inventory in
            guard entries.count == old.cases.count else { throw Self.invalid() }
            for (a, b) in zip(old.cases, entries) {
                guard a.caseID == b.caseID, a.stockID == b.stockID, a.tradingDay == b.tradingDay,
                      a.status == .pending || a == b else { throw Self.invalid() }
            }
            var next = old; next.cases = entries; next.status = status
            if status == .completed, next.collectionCompletedAt == nil {
                next.collectionCompletedAt = Int64(Date().timeIntervalSince1970 * 1000)
            }
            guard old.status != .completed || next == old else { throw Self.invalid() }
            let body = try encoded(next); try checkHashes(next, inventory)
            if next != old { try write(dir, "manifest.json", body: body, replace: true) }
        } }
    }
}


enum StockBacktestRequest {
    case calendar(market: WatchedStock.Market, date: String)
    case candles(stock: WatchedStock, interval: String, before: String, count: Int, adjusted: Bool)
}
enum StockBacktestReply {
    case calendar(value: MarketSessions, requestedAt: Int64)
    case candles(values: [StockCandle], nextBefore: String?, requestedAt: Int64)
}

@MainActor
final class StockBacktestStore: ObservableObject {
    struct Progress: Equatable { var completed = 0; var total = 0 }
    typealias Request = (StockBacktestRequest) async throws -> StockBacktestReply
    @Published private(set) var runs: [StockBacktestManifest] = []
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var progress = Progress()
    @Published private(set) var errorMessage: String?
    private static var sharedInstance: StockBacktestStore?
    static func shared(preferences: Preferences) -> StockBacktestStore {
        if let sharedInstance { return sharedInstance }
        let store = StockBacktestStore(preferences: preferences); sharedInstance = store; return store
    }
    private let archive: StockBacktestArchive
    private let requestOverride: Request?
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void
    private let revision: () -> Int
    private let provider: () -> StockQuoteSource
    private var generation = UUID()
    private var busy = false
    private var pageTask: Task<StockBacktestReply, Error>?
    private var lastRequestAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private struct Session { let start: Int64; let end: Int64; let fetchedAt: Int64; var previousDay = "" }
    private struct Skipped: Error { let reason: String }

    init(preferences: Preferences? = nil,
         archive: StockBacktestArchive? = nil,
         request: Request? = nil, now: @escaping () -> Date = Date.init,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
         revision: (() -> Int)? = nil, provider: (() -> StockQuoteSource)? = nil) {
        let archive = archive ?? StockBacktestArchive(directory: StockForecastJournal.fileURL.deletingLastPathComponent().appending(path: "Backtests"))
        self.archive = archive; requestOverride = request
        self.now = now; self.sleep = sleep
        self.revision = revision ?? { [weak preferences] in preferences?.stockSettingsRevision ?? 0 }
        self.provider = provider ?? { [weak preferences] in
            preferences?.stockQuoteSource ?? StockQuoteSource(rawValue: UserDefaults.standard.string(forKey: "stockQuoteSource") ?? "toss") ?? .toss
        }
        // No credential read or automatic collection. Do not let the initial listing overwrite a new run.
        let token = generation
        Task { [weak self, archive] in
            do {
                let listed = try await Task.detached { try archive.list() }.value
                guard let self, self.generation == token, !self.busy else { return }
                self.runs = listed
            } catch {
                guard let self, self.generation == token, !self.busy else { return }
                self.errorMessage = "archive_unavailable"
            }
        }
        preferences?.$stockSettingsRevision.dropFirst().sink { [weak self] _ in self?.cancel() }.store(in: &cancellables)
    }
    func cancel() { generation = UUID(); pageTask?.cancel() }
    private func check(_ token: UUID, _ revision: Int) throws {
        guard generation == token, self.revision() == revision, provider() == .toss, !Task.isCancelled else { throw CancellationError() }
    }
    private func io<T: Sendable>(_ operation: @escaping @Sendable (StockBacktestArchive) throws -> T) async throws -> T {
        let archive = archive
        return try await Task.detached { try operation(archive) }.value
    }
    private func transport() throws -> Request {
        if let requestOverride { return requestOverride }
        // Capture once on explicit start/resume. The shared API actor owns tokens and renewal.
        let credentials = TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else { throw TossInvestAPI.Failure.http(401) }
        return { request in
            var refreshed = false
            while true {
                try Task.checkCancellation()
                let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID, clientSecret: credentials.clientSecret)
                try Task.checkCancellation()
                do {
                    switch request {
                    case .calendar(let market, let day):
                        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = StockQuoteCodec.timeZone(for: market)
                        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
                        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                        guard let at = formatter.date(from: day), formatter.string(from: at) == day else { throw TossInvestAPI.Failure.invalidResponse }
                        let atRequest = Self.milliseconds(Date())
                        let value = try await TossInvestAPI.marketSessions(token: token.value, market: market, at: at)
                        return .calendar(value: value, requestedAt: atRequest)
                    case .candles(let stock, let interval, let before, let count, let adjusted):
                        guard count == 200, adjusted else { throw TossInvestAPI.Failure.invalidResponse }
                        return try await TossInvestAPI.backtestPage(token: token.value, stock: stock, interval: interval, before: before)
                    }
                } catch TossInvestAPI.Failure.http(401) where !refreshed {
                    refreshed = true
                    // No new token cache; body(for:) has invalidated the rejected shared token.
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }
    nonisolated private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private static func iso(_ time: Int64) -> String { ISO8601DateFormatter().string(from: StockBacktest.date(time)) }
    private static func day(_ time: Int64, _ market: WatchedStock.Market) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = StockQuoteCodec.timeZone(for: market)
        return StockBacktest.day(StockBacktest.date(time), calendar: calendar)
    }
    private func session(_ value: TradingSession?, market: WatchedStock.Market, fetchedAt: Int64) throws -> Session? {
        guard let value else { return nil }
        let start = Self.milliseconds(value.startTime), end = Self.milliseconds(value.endTime)
        guard StockBacktest.time(start), StockBacktest.time(end), end - start > 3_600_000,
              Self.day(start, market) == Self.day(end - 1, market) else { throw TossInvestAPI.Failure.invalidResponse }
        return Session(start: start, end: end, fetchedAt: fetchedAt)
    }
    private func fetch(_ input: StockBacktestRequest, using request: @escaping Request, token: UUID, revision: Int) async throws -> StockBacktestReply {
        try check(token, revision)
        if let lastRequestAt {
            let delay = 0.250 - now().timeIntervalSince(lastRequestAt)
            if delay > 0 { try await sleep(UInt64(ceil(delay * 1000))) }
        }
        try check(token, revision); lastRequestAt = now()
        let task = Task { try await request(input) }; pageTask = task
        defer { pageTask = nil }
        let reply = try await task.value; try check(token, revision)
        let requestedAt: Int64
        switch reply { case .calendar(_, let at), .candles(_, _, let at): requestedAt = at }
        guard StockBacktest.time(requestedAt), requestedAt <= Self.milliseconds(now()) else { throw TossInvestAPI.Failure.invalidResponse }
        return reply
    }
    private func publish(_ manifest: StockBacktestManifest) {
        if let n = runs.firstIndex(where: { $0.runID == manifest.runID }) { runs[n] = manifest } else { runs.append(manifest) }
        progress = Progress(completed: manifest.cases.filter { $0.status != .pending }.count, total: manifest.cases.count)
    }
    private func pause(_ manifest: StockBacktestManifest?, error: Error) async {
        errorMessage = error is CancellationError ? "collection_cancelled" : "collection_failed"
        if case TossInvestAPI.Failure.http(let code) = error, code == 401 || code == 403 { errorMessage = "authentication_paused" }
        guard var m = manifest, m.status != .completed else { return }
        do {
            let id = m.runID, entries = m.cases
            try await io { try $0.updateProgress(runID: id, entries: entries, status: .paused) }
            m.status = .paused; publish(m)
        } catch { errorMessage = "archive_unavailable" }
    }
    func start(symbols: [WatchedStock], sessions: Int = 60) async throws {
        guard !busy else { throw CocoaError(.validationMultipleErrors) }
        guard [20,60,120].contains(sessions), !symbols.isEmpty, symbols.count <= 30,
              Set(symbols.map(\.id)).count == symbols.count,
              symbols.allSatisfy({ WatchedStock.parse($0.id) == $0 && !$0.symbol.contains("..") }), provider() == .toss else { throw TossInvestAPI.Failure.invalidResponse }
        busy = true; generation = UUID(); let token = generation, revision = revision(), started = Self.milliseconds(now())
        let runID = UUID(); activeRunID = runID; progress = Progress(completed: 0, total: symbols.count * sessions)
        errorMessage = nil; var manifest: StockBacktestManifest?
        defer { busy = false; activeRunID = nil }
        do {
            let request = try transport(); try check(token, revision)
            var calendars: [String: Session] = [:], dates: [String: [String]] = [:]
            for market in Array(Set(symbols.map { $0.market.rawValue })).sorted() {
                let marketValue = WatchedStock.Market(rawValue: market)!
                var day = Self.day(started, marketValue), days: [String] = []
                for _ in 0...sessions {
                    guard case .calendar(let value, let at) = try await fetch(.calendar(market: marketValue, date: day), using: request, token: token, revision: revision) else { throw TossInvestAPI.Failure.invalidResponse }
                    var today = try session(value.today.regular(market: marketValue), market: marketValue, fetchedAt: at)
                    if let today, Self.day(today.start, marketValue) != day { throw TossInvestAPI.Failure.invalidResponse }
                    guard let previous = try session(value.previousBusinessDay.regular(market: marketValue), market: marketValue, fetchedAt: at),
                          previous.end <= started, Self.day(previous.start, marketValue) < day else { throw TossInvestAPI.Failure.invalidResponse }
                    today?.previousDay = Self.day(previous.start, marketValue)
                    if let today, today.end <= started { days.append(day); calendars[market + "|" + day] = today }
                    if days.count == sessions { break }
                    day = Self.day(previous.start, marketValue)
                }
                guard days.count == sessions else { throw TossInvestAPI.Failure.invalidResponse }; dates[market] = days
            }
            try check(token, revision)
            let entries = symbols.flatMap { stock in dates[stock.market.rawValue]!.map { day in
                StockBacktestManifest.Entry(caseID: "\(stock.market.rawValue)_\(stock.symbol)_\(day)", stockID: stock.id, tradingDay: day,
                    status: .pending, inputSHA256: nil, resultSHA256: nil, reason: nil)
            } }
            let m = StockBacktestManifest(version: 1, runID: runID, createdAt: started, collectionStartedAt: started,
                collectionCompletedAt: nil, protocolVersion: "replay-v1", codeVersion: "1.25.0/66", priceBasis: StockBacktest.priceBasis,
                cutoffMinutes: 60, sessions: sessions, symbols: symbols.map(\.id), models: StockBacktestArchive.models, status: .ready, cases: entries)
            manifest = m
            try await io { try $0.create(m) }; try check(token, revision); publish(m)
            try await collect(&manifest, saved: [:], calendars: calendars, request: request, token: token, revision: revision)
        } catch { await pause(manifest, error: error); throw error }
    }
    func resume(runID: UUID) async throws {
        guard !busy else { throw CocoaError(.validationMultipleErrors) }
        busy = true; generation = UUID(); let token = generation, revision = revision()
        activeRunID = runID; progress = Progress()
        errorMessage = nil; var manifest: StockBacktestManifest?
        defer { busy = false; activeRunID = nil }
        do {
            let loaded = try await io { try $0.collection(runID: runID) }; try check(token, revision)
            manifest = loaded.manifest; publish(loaded.manifest)
            if loaded.manifest.status == .completed { return }
            // A run whose pending cases already have valid bytes needs no credential read or public request.
            let missing = loaded.manifest.cases.contains { $0.status == .pending && loaded.saved[$0.caseID] == nil }
            let request: Request = missing ? try transport() : { _ in throw TossInvestAPI.Failure.invalidResponse }
            try await collect(&manifest, saved: loaded.saved, calendars: [:], request: request, token: token, revision: revision)
        } catch { await pause(manifest, error: error); throw error }
    }
    private func collect(_ manifest: inout StockBacktestManifest?, saved: [String: String], calendars initial: [String: Session],
                         request: @escaping Request, token: UUID, revision: Int) async throws {
        var m = manifest!, calendars = initial
        let id = m.runID, entries = m.cases
        try check(token, revision); try await io { try $0.updateProgress(runID: id, entries: entries, status: .running) }
        try check(token, revision); m.status = .running; manifest = m; publish(m)
        // Freeze every missing session before accepting any new case, including explicit resume.
        for e in m.cases where e.status == .pending && saved[e.caseID] == nil {
            let stock = WatchedStock.parse(e.stockID)!, key = stock.market.rawValue + "|" + e.tradingDay
            if calendars[key] == nil {
                guard case .calendar(let value, let at) = try await fetch(.calendar(market: stock.market, date: e.tradingDay), using: request, token: token, revision: revision),
                      var s = try session(value.today.regular(market: stock.market), market: stock.market, fetchedAt: at),
                      Self.day(s.start, stock.market) == e.tradingDay, s.end <= m.collectionStartedAt else { throw TossInvestAPI.Failure.invalidResponse }
                guard let previous = try session(value.previousBusinessDay.regular(market: stock.market), market: stock.market, fetchedAt: at),
                      previous.end < s.start, Self.day(previous.start, stock.market) < e.tradingDay else { throw TossInvestAPI.Failure.invalidResponse }
                s.previousDay = Self.day(previous.start, stock.market); calendars[key] = s
            }
        }
        for n in m.cases.indices {
            try check(token, revision); let e = m.cases[n]; if e.status != .pending { continue }
            if let hash = saved[e.caseID] { m.cases[n].status = .saved; m.cases[n].inputSHA256 = hash }
            else {
                let stock = WatchedStock.parse(e.stockID)!, key = stock.market.rawValue + "|" + e.tradingDay
                do {
                    let c = try await collectCase(stock: stock, entry: e, session: calendars[key]!, request: request, token: token, revision: revision)
                    try check(token, revision)
                    let hash = try await io { archive in
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        return try archive.saveCase(runID: id, body: encoder.encode(c))
                    }
                    try check(token, revision); m.cases[n].status = .saved; m.cases[n].inputSHA256 = hash
                } catch let error as Skipped {
                    try check(token, revision); m.cases[n].status = .skipped; m.cases[n].reason = error.reason
                }
            }
            try check(token, revision); let updated = m.cases
            try await io { try $0.updateProgress(runID: id, entries: updated, status: .running) }
            // Progress may already be committed at cancellation; keep its original bytes/identity.
            manifest = m; try check(token, revision); publish(m)
        }
        try check(token, revision); let finished = m.cases
        try await io { try $0.updateProgress(runID: id, entries: finished, status: .completed) }
        m = try await io { try $0.loadManifest(runID: id) }; manifest = m
        try check(token, revision); publish(m)
    }
    private func collectCase(stock: WatchedStock, entry: StockBacktestManifest.Entry, session: Session,
                             request: @escaping Request, token: UUID, revision: Int) async throws -> StockBacktestCase {
        let cutoff = session.end - 3_600_000, endCursor = Self.iso(session.end)
        guard case .candles(let daily, let dailyNext, let dailyAt) = try await fetch(.candles(stock: stock, interval: "1d", before: endCursor, count: 200, adjusted: true),
            using: request, token: token, revision: revision) else { throw TossInvestAPI.Failure.invalidResponse }
        try Self.validate(daily, before: session.end)
        if let dailyNext {
            guard let next = Self.timestamp(dailyNext), next < session.end,
                  let oldest = daily.map({ Self.milliseconds($0.end) }).min(), next <= oldest else { throw Skipped(reason: "repeated_cursor") }
        }
        var days: [String: StockBacktestInput.Minute] = [:]
        for b in daily {
            let row = Self.row(b), day = Self.day(row.end, stock.market)
            if let old = days[day], old != row { throw Skipped(reason: "conflicting_duplicate") }; days[day] = row
        }
        guard let target = days[entry.tradingDay] else { throw Skipped(reason: "session_target_mismatch") }
        let closes = days.keys.filter { $0 < entry.tradingDay }.sorted(by: >).prefix(61).map {
            StockBacktestInput.Close(date: days[$0]!.end, price: days[$0]!.close)
        }
        guard let previous = closes.first, Self.day(previous.date, stock.market) == session.previousDay else { throw Skipped(reason: "missing_previous_close") }
        var raw = 0, pages: [StockBacktestCase.Source.Page] = [], all: [Int64: StockBacktestInput.Minute] = [:]
        func page(_ before: String, seen: inout Set<Int64>) async throws -> (rows: [StockCandle], next: String?, at: Int64) {
            guard pages.count < 8, raw <= 1_200,
                  let bound = Self.timestamp(before) else { throw Skipped(reason: "collection_bounds") }
            guard case .candles(let values, let next, let at) = try await fetch(.candles(stock: stock, interval: "1m", before: before, count: 200, adjusted: true),
                using: request, token: token, revision: revision) else { throw TossInvestAPI.Failure.invalidResponse }
            try Self.validate(values, before: bound); raw += values.count
            guard raw <= 1_400 else { throw Skipped(reason: "collection_bounds") }
            if let next {
                guard let nextTime = Self.timestamp(next), nextTime < bound, !seen.contains(nextTime),
                      let oldest = values.map({ Self.milliseconds($0.end) }).min(), nextTime <= oldest else { throw Skipped(reason: "repeated_cursor") }
                seen.insert(nextTime)
            }
            pages.append(.init(before: before, nextBefore: next, fetchedAt: at))
            for b in values {
                let row = Self.row(b)
                if let old = all[row.end], old != row { throw Skipped(reason: "conflicting_duplicate") }; all[row.end] = row
            }
            return (values, next, at)
        }
        var proofSeen: Set<Int64> = [session.end]
        let proofReply = try await page(endCursor, seen: &proofSeen)
        guard let proof = all[session.end],
              abs(NSDecimalNumber(decimal: proof.close - target.close).doubleValue) <= NSDecimalNumber(decimal: target.close).doubleValue * 1e-8 else {
            throw Skipped(reason: "session_target_mismatch")
        }
        var inputs: [Int64: StockBacktestInput.Minute] = [:], seen: Set<Int64> = [cutoff], before = Self.iso(cutoff)
        while pages.count < 8, raw <= 1_200 {
            let reply = try await page(before, seen: &seen)
            for candle in reply.rows {
                let row = Self.row(candle)
                if row.end - 60_000 >= session.start, row.end <= cutoff { inputs[row.end] = row }
            }
            if reply.rows.contains(where: { Self.milliseconds($0.end) <= session.start + 60_000 }) || reply.next == nil { break }
            before = reply.next!
        }
        let minutes = inputs.values.sorted { $0.end < $1.end }
        guard let last = minutes.last, cutoff - last.end <= 120_000 else { throw Skipped(reason: "missing_cutoff_input") }
        let input = StockBacktestInput(version: 1, caseID: entry.caseID, stockID: entry.stockID, market: stock.market.rawValue,
            currency: stock.market == .kr ? "KRW" : "USD", tradingDay: entry.tradingDay, sessionStart: session.start, sessionEnd: session.end,
            cutoff: cutoff, inputBarEnd: last.end, inputPrice: last.close, previousClose: previous.price, priceBasis: StockBacktest.priceBasis,
            dailyCloses: closes, minutes: minutes)
        let c = StockBacktestCase(version: 1, input: input, target: .init(actualClose: target.close, candleAt: target.end, fetchedAt: dailyAt),
            source: .init(provider: "toss", calendarFetchedAt: session.fetchedAt, dailyFetchedAt: dailyAt, minutePages: pages))
        guard dailyAt >= session.end, proofReply.at >= session.end, c.isValid else { throw Skipped(reason: "invalid_collected_case") }; return c
    }
    nonisolated static func timestamp(_ text: String) -> Int64? {
        guard StockBacktest.cursor(text) else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return date.map(milliseconds)
    }
    nonisolated private static func row(_ b: StockCandle) -> StockBacktestInput.Minute {
        .init(end: milliseconds(b.end), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume)
    }
    nonisolated static func validate(_ values: [StockCandle], before: Int64) throws {
        guard values.count <= 200 else { throw Skipped(reason: "invalid_candle_page") }
        var direction = 0
        for (n, candle) in values.enumerated() {
            let b = row(candle)
            guard StockBacktest.time(b.end), b.end <= before, [b.open,b.high,b.low,b.close].allSatisfy(StockBacktest.positive),
                  StockBacktest.finite(b.volume), b.volume >= 0, b.high >= max(b.open,b.close), b.low <= min(b.open,b.close) else { throw Skipped(reason: "invalid_candle_page") }
            if n > 0 {
                let delta = b.end - milliseconds(values[n-1].end), d = delta == 0 ? 0 : delta > 0 ? 1 : -1
                guard d == 0 || direction == 0 || direction == d else { throw Skipped(reason: "invalid_candle_order") }
                if d != 0 { direction = d }
            }
        }
    }
}
