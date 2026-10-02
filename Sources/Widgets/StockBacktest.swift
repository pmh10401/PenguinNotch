import Foundation
import CryptoKit
import Darwin

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

struct StockBacktestManifest: Codable, Equatable {
    enum Status: String, Codable { case ready, running, paused, completed }
    struct Entry: Codable, Equatable {
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
    /// JSON boundary for later callers; reject unknown fields before Codable can discard them.
    static func decodeCase(_ data: Data) throws -> StockBacktestCase {
        let object = try JSONSerialization.jsonObject(with: data)
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
struct StockBacktestArchive {
    let directory: URL
    var fault: ((String) throws -> Void)? = nil // Internal fault injection for temp-only preservation tests.
    private static let limit = 2 * 1024 * 1024
    static let models = ["GBM daily zero drift v1 / replay v1", "GBM 1m zero drift v1 / replay v1", "GBM 10m zero drift v1 / replay v1"]
    private static func invalid() -> CocoaError { CocoaError(.fileReadCorruptFile) }
    static func hash(_ body: Data) -> String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    private static func object(_ body: Data) throws -> Any {
        guard body.count <= limit, String(data: body, encoding: .utf8) != nil else { throw invalid() }
        return try JSONSerialization.jsonObject(with: body)
    }
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
        let row = try StockBacktest.keys(object(body), ["version", "runID", "createdAt", "collectionStartedAt", "collectionCompletedAt",
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
              Set(m.cases.map(\.tradingDay)).count <= m.sessions,
              (m.status == .completed) == (m.collectionCompletedAt != nil) else { throw invalid() }
        for e in m.cases {
            guard identity(e.caseID, stockID: e.stockID, day: e.tradingDay), m.symbols.contains(e.stockID),
                  digest(e.inputSHA256), digest(e.resultSHA256), e.reason.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw invalid() }
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
        let row = try StockBacktest.keys(object(body), ["version", "caseID", "inputSHA256", "calculationVersion", "computedAt", "outcomes"])
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
    private func run<T>(_ root: Int32, _ id: UUID, _ operation: (Int32, StockBacktestManifest) throws -> T) throws -> T {
        let dir = try folder(root, id.uuidString.lowercased()); defer { Darwin.close(dir) }
        guard let body = try read(dir, "manifest.json") else { throw Self.invalid() }
        let m = try Self.decodeManifest(body); guard m.runID == id else { throw Self.invalid() }
        try integrity(dir, m)
        return try operation(dir, m)
    }
    private func integrity(_ dir: Int32, _ m: StockBacktestManifest) throws {
        guard try names(dir).allSatisfy({ ["manifest.json", "cases", "results"].contains($0) || $0.hasPrefix(".tmp-") }) else { throw Self.invalid() }
        for name in try names(dir) where name.hasPrefix(".tmp-") { _ = try read(dir, name) }
        var caseHashes: [String: String] = [:], resultHashes: [String: String] = [:]
        for kind in ["cases", "results"] {
            let sub = try folder(dir, kind); defer { Darwin.close(sub) }
            for name in try names(sub) {
                guard let body = try read(sub, name) else { throw Self.invalid() }
                if name.hasPrefix(".tmp-") { continue } // Crash leftovers are preserved, never used as evidence.
                guard name.hasSuffix(".json") else { throw Self.invalid() }
                let id = String(name.dropLast(5))
                guard let entry = m.cases.first(where: { $0.caseID == id }), entry.status != .skipped else { throw Self.invalid() }
                if kind == "cases" {
                    _ = try Self.object(body); let c = try StockBacktest.decodeCase(body)
                    guard c.input.caseID == id, c.input.stockID == entry.stockID, c.input.tradingDay == entry.tradingDay else { throw Self.invalid() }
                    caseHashes[id] = Self.hash(body)
                } else {
                    let r = try Self.decodeResult(body)
                    guard r.caseID == id, r.inputSHA256 == caseHashes[id], Set(r.outcomes.map(\.model)) == Set(m.models) else { throw Self.invalid() }
                    resultHashes[id] = Self.hash(body)
                }
            }
        }
        for e in m.cases {
            if let h = e.inputSHA256, h != caseHashes[e.caseID] { throw Self.invalid() }
            if let h = e.resultSHA256, h != resultHashes[e.caseID] { throw Self.invalid() }
        }
    }
    func list() throws -> [StockBacktestManifest] {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Self.invalid() }; return []
        }
        return try locked { root in
            try names(root).map { name in
                guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { throw Self.invalid() }
                return try run(root, id) { _, m in m }
            }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    func create(_ manifest: StockBacktestManifest) throws {
        let body = try encoded(manifest)
        try locked(create: true) { root in
            let id = manifest.runID.uuidString.lowercased()
            if try names(root).contains(id) {
                try run(root, manifest.runID) { _, old in guard old == manifest else { throw Self.invalid() } }; return
            }
            guard manifest.status == .ready, manifest.cases.allSatisfy({ $0.status == .pending }) else { throw Self.invalid() }
            let dir = try folder(root, id, create: true); defer { Darwin.close(dir) }
            for name in ["cases", "results"] { Darwin.close(try folder(dir, name, create: true)) }
            try write(dir, "manifest.json", body: body); guard fsync(root) == 0 else { throw Self.invalid() }
        }
    }
    func loadManifest(runID: UUID) throws -> StockBacktestManifest {
        try locked { root in try run(root, runID) { _, m in m } }
    }
    func saveCase(runID: UUID, body: Data) throws -> String {
        _ = try Self.object(body); let c = try StockBacktest.decodeCase(body)
        return try locked { root in try run(root, runID) { dir, m in
            guard let e = m.cases.first(where: { $0.caseID == c.input.caseID }), e.status != .skipped,
                  e.stockID == c.input.stockID, e.tradingDay == c.input.tradingDay else { throw Self.invalid() }
            let sub = try folder(dir, "cases"); defer { Darwin.close(sub) }
            if m.status == .completed, try read(sub, c.input.caseID + ".json") != body { throw Self.invalid() }
            try write(sub, c.input.caseID + ".json", body: body); return Self.hash(body)
        } }
    }
    func loadCase(runID: UUID, caseID: String) throws -> (body: Data, sha256: String) {
        guard Self.safeCaseID(caseID) else { throw Self.invalid() }
        return try locked { root in try run(root, runID) { dir, _ in
            let sub = try folder(dir, "cases"); defer { Darwin.close(sub) }
            guard let body = try read(sub, caseID + ".json") else { throw Self.invalid() }; return (body, Self.hash(body))
        } }
    }
    func saveResult(runID: UUID, body: Data) throws -> String {
        let r = try Self.decodeResult(body)
        return try locked { root in try run(root, runID) { dir, m in
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
        return try locked { root in try run(root, runID) { dir, m in
            guard m.cases.contains(where: { $0.caseID == caseID }) else { throw Self.invalid() }
            let sub = try folder(dir, "results"); defer { Darwin.close(sub) }; return try read(sub, caseID + ".json")
        } }
    }
    func updateProgress(runID: UUID, entries: [StockBacktestManifest.Entry], status: StockBacktestManifest.Status) throws {
        try locked { root in try run(root, runID) { dir, old in
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
            let body = try encoded(next); try integrity(dir, next)
            if next != old { try write(dir, "manifest.json", body: body, replace: true) }
        } }
    }
}
