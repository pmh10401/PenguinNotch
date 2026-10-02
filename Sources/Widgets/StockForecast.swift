import Combine
import Foundation

struct TossResult<Value: Decodable>: Decodable { let result: Value }

struct TossAccount: Decodable, Identifiable {
    let accountNo: String
    let accountSeq: Int
    let accountType: String
    var id: Int { accountSeq }
    var maskedNumber: String { accountNo.count > 4 ? "•••• \(accountNo.suffix(4))" : "••••" }
}

struct PortfolioHoldings: Decodable { let items: [PortfolioHolding] }

struct PortfolioHolding: Decodable, Identifiable {
    let symbol: String
    let name: String
    let marketCountry: String
    let currency: String

    var id: String { "\(marketCountry):\(symbol)" }
    var stock: WatchedStock? { WatchedStock.parse(id) }
}

/// Public symbol metadata shared by watchlist and optional holding forecasts; not a position.
struct StockForecastTarget: Identifiable {
    let stock: WatchedStock
    let name: String
    var id: String { stock.id }
    var currency: String { stock.market == .kr ? "KRW" : "USD" }
}

struct MarketSessions: Decodable {
    let today: MarketSessionDay
    let previousBusinessDay: MarketSessionDay
    let nextBusinessDay: MarketSessionDay?
}

struct MarketSessionDay: Decodable {
    let integrated: IntegratedMarket?
    let regularMarket: TradingSession?
    let dayMarket: TradingSession?
    let preMarket: TradingSession?
    let afterMarket: TradingSession?

    func regular(market: WatchedStock.Market) -> TradingSession? {
        market == .kr ? integrated?.regularMarket : regularMarket
    }
}

struct IntegratedMarket: Decodable { let regularMarket: TradingSession? }

struct TradingSession: Decodable {
    let startTime: Date
    let endTime: Date

    func contains(_ date: Date) -> Bool { startTime <= date && date < endTime }
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
}

/// The completed daily candles that were actually available to the prediction.
/// Newest first; no positions, credentials, or subsequently fetched prices.
struct StockForecastEvidence: Codable, Hashable {
    struct Close: Codable, Hashable {
        let date: Date
        let price: Decimal
    }
    let closes: [Close]
    let adjusted: Bool

    init(closes: [Close]) {
        self.closes = closes
        adjusted = true
    }

    var dailyVolatility: Double? {
        StockForecast.dailyVariance(closes.map(\.price)).map { sqrt($0) }
    }

    func historicalReturn(sessions: Int) -> Double? {
        guard sessions > 0, closes.count > sessions, closes[sessions].price > 0 else { return nil }
        let value = NSDecimalNumber(decimal: closes[0].price / closes[sessions].price - 1).doubleValue
        return value.isFinite ? value : nil
    }

    func isValid(for record: StockForecastRecord) -> Bool {
        guard adjusted, closes.count == record.observations + 1, closes.first?.price == record.previousClose,
              dailyVolatility != nil,
              closes.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && $0.price > 0
                  && NSDecimalNumber(decimal: $0.price).doubleValue.isFinite }) else { return false }
        let calendar = record.marketCalendar
        let days = closes.map { calendar.startOfDay(for: $0.date) }
        return days[0] < calendar.startOfDay(for: record.sessionStart)
            && zip(days, days.dropFirst()).allSatisfy { $0 > $1 }
    }
}

/// Zero-drift lognormal continuation. The current quote is the conditional
/// expected close; daily close-to-close variance only sizes the remaining risk.
/// These are model probabilities, not calibrated forecasts or trading signals.
struct StockForecast {
    let riseProbability: Double
    let expectedClose: Decimal
    let observations: Int
    let lowerClose: Decimal
    let upperClose: Decimal

    static func estimate(price: Decimal, completedCloses: [Decimal],
                         trading: TradingSession, now: Date) -> StockForecast? {
        guard trading.contains(now), trading.duration > 0, price > 0,
              completedCloses.count >= 21,
              let previous = completedCloses.first, previous > 0 else { return nil }
        guard let variance = dailyVariance(completedCloses) else { return nil }
        let remaining = trading.endTime.timeIntervalSince(now) / trading.duration
        return distribution(price: price, previous: previous, variance: variance * remaining,
                            observations: completedCloses.count - 1)
    }

    /// Selected bars change volatility, not the zero-drift expected price or target close.
    /// Intraday estimates use only completed regular-session bars, never overnight gaps.
    static func chartEstimate(record: StockForecastRecord, minutes: [StockCandle],
                              interval: StockChartInterval, now: Date) -> StockForecast? {
        let trading = TradingSession(startTime: record.sessionStart, endTime: record.sessionEnd)
        guard record.isValid, trading.contains(now), record.createdAt <= now,
              now.timeIntervalSince(record.quoteAt) <= 120 else { return nil }
        if interval == .day {
            guard let evidence = record.evidence else { return nil }
            return estimate(price: record.inputPrice, completedCloses: evidence.closes.map(\.price),
                            trading: trading, now: record.quoteAt)
        }
        return intradayEstimate(price: record.inputPrice, previous: record.previousClose, bars: minutes,
                                trading: trading, at: record.quoteAt, interval: interval)
    }

    /// Pure intraday calculation shared by live charts and validated historical inputs.
    static func intradayEstimate(price: Decimal, previous: Decimal, bars: [StockCandle],
                                 trading: TradingSession, at: Date, interval: StockChartInterval) -> StockForecast? {
        guard interval != .day, trading.contains(at), trading.duration > 0,
              price > 0, previous > 0 else { return nil }
        let duration: TimeInterval = interval == .minute ? 60 : 600
        let bars = StockQuoteCodec.completedRegularBars(bars, trading: trading,
                                                        through: at, interval: interval)
        guard let last = bars.last, at.timeIntervalSince(last.end) <= duration + 120 else { return nil }
        var returns: [Double] = []
        for (next, prior) in zip(bars.dropFirst(), bars).reversed() {
            guard abs(next.end.timeIntervalSince(prior.end) - duration) < 0.01 else { break }
            let value = log(NSDecimalNumber(decimal: next.close / prior.close).doubleValue)
            guard value.isFinite else { return nil }
            returns.append(value)
        }
        guard returns.count >= 10 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let perBar = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        let remaining = trading.endTime.timeIntervalSince(at) / duration
        return distribution(price: price, previous: previous,
                            variance: perBar * remaining, observations: returns.count)
    }

    private static func distribution(price: Decimal, previous: Decimal, variance: Double,
                                     observations: Int) -> StockForecast? {
        let sigma = sqrt(variance)
        guard sigma.isFinite, sigma > 0 else { return nil }
        let logMove = log(NSDecimalNumber(decimal: price / previous).doubleValue)
        let z = (logMove - variance / 2) / sigma
        guard z.isFinite else { return nil }
        let probability = min(max(0.5 * (1 + erf(z / sqrt(2))), 0), 1)
        let current = NSDecimalNumber(decimal: price).doubleValue
        let medianLogMove = -variance / 2
        let lower = current * exp(medianLogMove - 1.2815515655446004 * sigma)
        let upper = current * exp(medianLogMove + 1.2815515655446004 * sigma)
        guard lower.isFinite, upper.isFinite, lower > 0 else { return nil }
        return StockForecast(riseProbability: probability, expectedClose: price,
                             observations: observations, lowerClose: Decimal(lower), upperClose: Decimal(upper))
    }

    static func dailyVariance(_ closes: [Decimal]) -> Double? {
        let values = closes.map { NSDecimalNumber(decimal: $0).doubleValue }
        guard values.count >= 21, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let returns = zip(values, values.dropFirst()).map { log($0.0) - log($0.1) }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        return variance.isFinite ? variance : nil
    }
}

/// Display history is separate from scored forecasts and never stores candle evidence or positions.
/// Each stock/day is an atomic, bounded archive; older trading days are never rewritten or deleted.
@MainActor
final class StockCloseHistory {
    static var directoryURL: URL {
        StockForecastJournal.fileURL.deletingLastPathComponent().appending(path: "CloseEstimates")
    }

    struct Point: Codable, Equatable {
        let stockID: String
        let currency: String
        let model: String
        let createdAt: Date
        let quoteAt: Date
        let sessionStart: Date
        let sessionEnd: Date
        let expectedClose: Decimal

        init(_ record: StockForecastRecord) {
            stockID = record.stockID
            currency = record.currency
            model = record.model
            createdAt = record.createdAt
            quoteAt = record.quoteAt
            sessionStart = record.sessionStart
            sessionEnd = record.sessionEnd
            expectedClose = record.expectedClose
        }

        var marketCalendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = StockQuoteCodec.timeZone(for: WatchedStock.parse(stockID)?.market ?? .us)
            return calendar
        }
        var day: String { StockCloseHistory.day(sessionStart, calendar: marketCalendar) }
        var minute: Double { floor(createdAt.timeIntervalSince1970 / 60) }

        func isValid(now: Date) -> Bool {
            guard let stock = WatchedStock.parse(stockID), stock.id == stockID,
                  currency == (stock.market == .kr ? "KRW" : "USD"),
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 100,
                  model.rangeOfCharacter(from: .controlCharacters) == nil,
                  expectedClose > 0, NSDecimalNumber(decimal: expectedClose).doubleValue.isFinite,
                  [createdAt, quoteAt, sessionStart, sessionEnd].allSatisfy({
                      (0..<253_402_300_800).contains($0.timeIntervalSince1970)
                  }),
                  sessionStart <= quoteAt, quoteAt <= createdAt, createdAt < sessionEnd,
                  createdAt <= now, createdAt.timeIntervalSince(quoteAt) <= 120 else { return false }
            let calendar = marketCalendar
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: sessionStart))!
            return sessionEnd <= nextDay
        }
    }

    private struct Archive: Codable {
        var version = 1
        let stockID: String
        let points: [Point]
    }
    private enum Failure { case read, write }
    private let directory: URL?
    private var failures: [URL: Failure] = [:]
    private(set) var points: [String: [Point]] = [:]
    var errorMessage: String? {
        if failures.values.contains(.read) {
            return L10n.t("Could not read close history. Unreadable files will not be overwritten.")
        }
        return failures.isEmpty ? nil
            : L10n.t("Could not save close history. Check disk space and permissions.")
    }

    init(directory: URL? = nil, now: Date = Date()) {
        self.directory = directory
        guard let directory else { return }
        guard directory.isFileURL else { failures[directory] = .read; return }
        // Load only today's market dates. Lifetime history stays on disk, not in memory.
        let days = Set([WatchedStock.Market.kr, .us].map { market in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = StockQuoteCodec.timeZone(for: market)
            return Self.day(now, calendar: calendar)
        })
        for day in days {
            let folder = directory.appending(path: day)
            do {
                let files = try FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for file in files where file.pathExtension == "json" {
                    do {
                        let loaded = try read(file, now: now)
                        if let first = loaded.first, first.marketCalendar.isDate(first.sessionStart, inSameDayAs: now) {
                            points[first.stockID] = loaded
                        }
                    } catch { failures[file] = .read }
                }
            } catch {
                if !Self.isMissing(error) { failures[folder] = .read }
            }
        }
    }

    func record(_ snapshots: [StockForecastRecord], now: Date) {
        guard directory?.isFileURL != false else { return }
        for record in snapshots where record.isValid && record.actualClose == nil {
            let point = Point(record)
            guard point.isValid(now: now), now.timeIntervalSince(point.createdAt) <= 120,
                  point.marketCalendar.isDate(point.sessionStart, inSameDayAs: now) else { continue }
            if let last = points[point.stockID]?.last, point.createdAt <= last.createdAt { continue }
            let file = directory?.appending(path: point.day).appending(path: Self.filename(point.stockID))
            var existing = (points[point.stockID] ?? []).filter { $0.day == point.day }
            if let file {
                // Re-read before every write, including files modified since launch. Never replace a bad archive.
                guard failures[file] != .read, failures[file.deletingLastPathComponent()] != .read else { continue }
                do { existing = try read(file, now: now) }
                catch { failures[file] = .read; continue }
            }
            if let last = existing.last {
                guard point.minute > last.minute, point.quoteAt > last.quoteAt else { continue }
            }
            guard existing.count < 1440 else { continue }
            let next = existing + [point]
            do {
                if let file {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .millisecondsSince1970
                    // ponytail: at most one day of minute points per write; move I/O off-main if large watchlists stall it.
                    try encoder.encode(Archive(stockID: point.stockID, points: next)).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    failures[file] = nil
                }
                points[point.stockID] = next
            } catch {
                if let file { failures[file] = .write }
            }
        }
    }

    private func read(_ file: URL, now: Date) throws -> [Point] {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let archive = try decoder.decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1, (1...1440).contains(archive.points.count),
                  let stock = WatchedStock.parse(archive.stockID), stock.id == archive.stockID,
                  file.lastPathComponent == Self.filename(stock.id),
                  archive.points.allSatisfy({ $0.isValid(now: now) && $0.stockID == stock.id
                      && $0.day == file.deletingLastPathComponent().lastPathComponent }),
                  zip(archive.points, archive.points.dropFirst()).allSatisfy({
                      $0.minute < $1.minute && $0.quoteAt < $1.quoteAt
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            return archive.points
        } catch {
            if Self.isMissing(error) { return [] }
            throw error
        }
    }

    private static func filename(_ stockID: String) -> String {
        stockID.replacingOccurrences(of: ":", with: "-") + ".json"
    }
    nonisolated private static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
    }
}

/// Account numbers and positions remain in memory. The selected account's
/// opaque sequence is a preference. The app owns one opt-in polling loop, so
/// closing Settings does not miss the scheduled prediction or its later score.
@MainActor
final class StockForecastStore: ObservableObject {
    static let shared = StockForecastStore(journal: StockForecastJournal(url: StockForecastJournal.fileURL),
                                           closeHistoryDirectory: StockCloseHistory.directoryURL,
                                           codexAnalyses: .shared)
    let journal: StockForecastJournal
    private let codexAnalyses: StockCodexAnalysisStore?
    private let history: StockCloseHistory
    private let privateSession = URLSession(configuration: .ephemeral)
    @Published private(set) var accounts: [TossAccount] = []
    @Published private(set) var loadingAccounts = false
    @Published private(set) var accountMessage: String?
    @Published private(set) var holdings: [PortfolioHolding] = []
    @Published private(set) var forecasts: [String: StockForecast] = [:]
    @Published private(set) var reasons: [String: String] = [:]
    @Published private(set) var message: String?
    @Published private(set) var loading = false
    @Published private(set) var candidates: [StockForecastRecord] = []
    /// Compact, locally saved display samples; never pooled into the scored journal.
    @Published private(set) var closeHistory: [String: [StockCloseHistory.Point]] = [:]
    @Published private(set) var closeHistoryError: String?

    private var task: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var settingsRevision: Int?
    private weak var preferences: Preferences?
    private var settingsVisible = false
    private var chartObservers: Set<UUID> = []

    /// Nil storage URLs keep tests isolated from the user's archives.
    init(journal: StockForecastJournal? = nil, closeHistoryDirectory: URL? = nil,
         codexAnalyses: StockCodexAnalysisStore? = nil, now: Date = Date()) {
        self.journal = journal ?? StockForecastJournal()
        self.codexAnalyses = codexAnalyses
        history = StockCloseHistory(directory: closeHistoryDirectory, now: now)
        closeHistory = history.points
        closeHistoryError = history.errorMessage
    }

    func start(preferences: Preferences) {
        self.preferences = preferences
        subscription = preferences.$portfolioForecastEnabled
            .combineLatest(preferences.$tossAccountSeq, preferences.$stockSettingsRevision, preferences.$recordsStockForecasts)
            .combineLatest(preferences.$stockSymbols)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restart() }
    }

    func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        if preferences?.recordsStockForecasts != true { restart() }
    }

    func setChartVisible(_ visible: Bool, observer: UUID) {
        let wasVisible = !chartObservers.isEmpty
        if visible { chartObservers.insert(observer) } else { chartObservers.remove(observer) }
        if wasVisible != !chartObservers.isEmpty { restart() }
    }

    private func restart() {
        guard let preferences else { return }
        task?.cancel()
        if settingsRevision != preferences.stockSettingsRevision {
            clear()
            settingsRevision = preferences.stockSettingsRevision
        }
        guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss else { clear(); return }
        if accountSeq != preferences.tossAccountSeq { clearSelection() }
        // Preserve the observed curve when a hover closes, without polling in the background.
        guard settingsVisible || !chartObservers.isEmpty || preferences.recordsStockForecasts else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(preferences: preferences)
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        subscription = nil
        clear()
    }

    func saveCurrent(now: Date = Date()) -> Int {
        journal.record(candidates.filter { now >= $0.createdAt && now < $0.sessionEnd
            && now.timeIntervalSince($0.createdAt) <= 90 })
    }

    func retainCloseHistory(_ records: [StockForecastRecord], now: Date = Date()) {
        history.record(records, now: now)
        closeHistory = history.points
        closeHistoryError = history.errorMessage
    }

    func closeHistory(for stock: WatchedStock, now: Date) -> [StockCloseHistory.Point] {
        let today = (closeHistory[stock.id] ?? []).filter {
            $0.createdAt <= now && $0.marketCalendar.isDate($0.sessionStart, inSameDayAs: now)
        }
        guard let last = today.last else { return [] }
        // Do not join different model/target curves. Their original samples stay on disk.
        return today.filter {
            $0.model == last.model && $0.sessionStart == last.sessionStart && $0.sessionEnd == last.sessionEnd
        }
    }

    private var accountSeq = 0
    private var holdingsAt: Date?
    private var completedCloses: [String: [StockForecastEvidence.Close]] = [:]
    private var historySession: [String: Date] = [:]
    private var historyAttempt: [String: Date] = [:]

    func targets(for preferences: Preferences) -> [StockForecastTarget] {
        var targets = preferences.orderedStocks.map { stock in
            StockForecastTarget(stock: stock, name: stock.market == .kr
                ? KoreanStockDirectory.shared.name(for: stock.symbol) ?? stock.symbol : stock.symbol)
        }
        var ids = Set(targets.map(\.id))
        if preferences.tossAccountSeq > 0, preferences.tossAccountSeq == accountSeq {
            for holding in holdings {
                guard let stock = holding.stock, holding.currency == (stock.market == .kr ? "KRW" : "USD"),
                      ids.insert(stock.id).inserted else { continue }
                targets.append(StockForecastTarget(stock: stock, name: holding.name.isEmpty ? stock.symbol : holding.name))
            }
        }
        return targets
    }

    /// Only the explicit Settings button calls this when no account is selected. Never auto-select an account.
    func loadAccounts(preferences: Preferences, session suppliedSession: URLSession? = nil,
                      credentials supplied: (clientID: String, clientSecret: String)? = nil) async {
        guard !loadingAccounts, preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss else { return }
        loadingAccounts = true
        accountMessage = nil
        let revision = preferences.stockSettingsRevision
        defer { loadingAccounts = false }
        do {
            let session = suppliedSession ?? privateSession
            let credentials = supplied ?? TossCredentials.load()
            guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
                accountMessage = L10n.t("Save Toss Securities API keys to view stock estimates.")
                return
            }
            let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                           clientSecret: credentials.clientSecret, session: session)
            try Task.checkCancellation()
            guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss,
                  preferences.stockSettingsRevision == revision else { return }
            let fetched = try await TossInvestAPI.accounts(token: token.value, session: session)
            try Task.checkCancellation()
            guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss,
                  preferences.stockSettingsRevision == revision else { return }
            accounts = fetched.filter { $0.accountType == "BROKERAGE" }
            if accounts.isEmpty { accountMessage = L10n.t("No supported Toss Securities account was found.") }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss,
                  preferences.stockSettingsRevision == revision else { return }
            accountMessage = L10n.t("Could not load accounts. Watchlist estimates remain available.")
        }
    }

    func clear() {
        accounts = []
        accountMessage = nil
        holdings = []
        forecasts = [:]
        reasons = [:]
        message = nil
        loading = false
        candidates = []
        accountSeq = 0
        holdingsAt = nil
        completedCloses = [:]
        historySession = [:]
        historyAttempt = [:]
    }

    func clearSelection() {
        clearHoldings()
        accountMessage = nil
        accountSeq = 0
    }

    func refresh(preferences: Preferences, session suppliedSession: URLSession? = nil, now suppliedNow: Date? = nil,
                 credentials supplied: (clientID: String, clientSecret: String)? = nil) async {
        let now = suppliedNow ?? Date()
        guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss else { clear(); return }
        let selected = preferences.tossAccountSeq
        let revision = preferences.stockSettingsRevision
        let watched = preferences.stockSymbols
        func checkCurrentSettings() throws {
            try Task.checkCancellation()
            guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss,
                  preferences.tossAccountSeq == selected, preferences.stockSettingsRevision == revision,
                  preferences.stockSymbols == watched else { throw CancellationError() }
        }
        let session = suppliedSession ?? privateSession
        let credentials = supplied ?? TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            forecasts = [:]
            candidates = []
            message = L10n.t("Save Toss Securities API keys to view stock estimates.")
            return
        }
        loading = candidates.isEmpty
        defer { loading = false }
        do {
            let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                             clientSecret: credentials.clientSecret,
                                                             session: session)
            try checkCurrentSettings()
            await journal.reconcile(token: token.value, session: session, now: now)
            try checkCurrentSettings()
            await codexAnalyses?.reconcile(token: token.value, session: session, now: now)
            try checkCurrentSettings()
            if accountSeq != selected {
                clearHoldings()
                accountMessage = nil
                accountSeq = selected
            }
            if selected > 0 {
                accountMessage = nil
                do {
                    if accounts.isEmpty {
                        let fetched = try await TossInvestAPI.accounts(token: token.value, session: session)
                        try checkCurrentSettings()
                        accounts = fetched.filter { $0.accountType == "BROKERAGE" }
                    }
                    if accounts.contains(where: { $0.accountSeq == selected }) {
                        if holdingsAt == nil || now.timeIntervalSince(holdingsAt!) >= 300 {
                            let fetched = try await TossInvestAPI.holdings(token: token.value, accountSeq: selected, session: session)
                            try checkCurrentSettings()
                            holdings = fetched
                            holdingsAt = now
                        }
                        if holdings.isEmpty { accountMessage = L10n.t("This account has no supported stock holdings.") }
                    } else {
                        holdings = []
                        holdingsAt = nil
                        accountMessage = L10n.t("Select an account to view its holdings.")
                    }
                } catch is CancellationError { return }
                catch {
                    try checkCurrentSettings()
                    holdings = []
                    holdingsAt = nil
                    accountMessage = L10n.t("Could not load optional holdings. Watchlist estimates remain available.")
                }
            }
            let targets = targets(for: preferences)
            guard !targets.isEmpty else {
                forecasts = [:]
                candidates = []
                reasons = [:]
                message = L10n.t("Add watchlist stocks to view estimates, or select an optional account.")
                return
            }

            var sessions: [WatchedStock.Market: TradingSession] = [:]
            for market in [WatchedStock.Market.kr, .us]
            where targets.contains(where: { $0.stock.market == market }) {
                if let trading = try await TossInvestAPI.regularSession(token: token.value, market: market,
                                                                         at: now, session: session) {
                    sessions[market] = trading
                }
                try checkCurrentSettings()
            }
            let active = targets.map(\.stock).filter { sessions[$0.market] != nil }
            var quotes: [String: StockTick] = [:]
            for offset in stride(from: 0, to: active.count, by: 200) {
                let batch = Array(active[offset..<min(offset + 200, active.count)])
                quotes.merge(try await TossInvestAPI.timestampedPrices(token: token.value,
                                                                        symbols: batch.map(\.symbol), session: session)) { _, new in new }
                try checkCurrentSettings()
            }
            var next: [String: StockForecast] = [:]
            var nextCandidates: [StockForecastRecord] = []
            var nextReasons: [String: String] = [:]
            for target in targets {
                let stock = target.stock
                guard let trading = sessions[stock.market] else {
                    nextReasons[stock.id] = L10n.t("Close estimates run during the regular session only. Extended-hours trading is separate.")
                    continue
                }
                let quoteClock = suppliedNow ?? Date()
                guard let quote = quotes[stock.id], quote.price > 0,
                      trading.contains(quote.timestamp),
                      (0...120).contains(quoteClock.timeIntervalSince(quote.timestamp)) else {
                    nextReasons[stock.id] = L10n.t("No recent trade price is available.")
                    continue
                }
                if historySession[stock.id] != trading.startTime {
                    historySession[stock.id] = trading.startTime
                    completedCloses[stock.id] = nil
                    historyAttempt[stock.id] = nil
                }
                if (completedCloses[stock.id]?.count ?? 0) < 21,
                   now.timeIntervalSince(historyAttempt[stock.id] ?? .distantPast) >= 600 {
                    historyAttempt[stock.id] = now
                    if let candles = try? await TossInvestAPI.forecastCloses(token: token.value,
                                                                              stock: stock, session: session) {
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = StockQuoteCodec.timeZone(for: stock.market)
                        let today = calendar.startOfDay(for: trading.startTime)
                        completedCloses[stock.id] = candles
                            .filter { calendar.startOfDay(for: $0.date) < today }
                            .sorted { $0.date > $1.date }
                            .prefix(61)
                            .map { StockForecastEvidence.Close(date: $0.date, price: $0.close) }
                    }
                    try checkCurrentSettings()
                    try await Task.sleep(for: .milliseconds(60)) // below the chart endpoint's 20/s limit
                }
                // Record when inputs actually finished loading, never the request's earlier start time.
                let predictionTime = suppliedNow ?? Date()
                guard (0...120).contains(predictionTime.timeIntervalSince(quote.timestamp)) else {
                    nextReasons[stock.id] = L10n.t("No recent trade price is available.")
                    continue
                }
                let evidence = StockForecastEvidence(closes: completedCloses[stock.id] ?? [])
                if trading.contains(predictionTime), let forecast = StockForecast.estimate(price: quote.price,
                                                           completedCloses: evidence.closes.map(\.price),
                                                           trading: trading, now: quote.timestamp),
                   let previousClose = evidence.closes.first?.price {
                    let record = StockForecastRecord(stockID: stock.id, name: target.name,
                        currency: target.currency, model: StockForecastRecord.modelVersion, capture: .manual,
                        createdAt: predictionTime, quoteAt: quote.timestamp, sessionStart: trading.startTime,
                        sessionEnd: trading.endTime, previousClose: previousClose, inputPrice: quote.price,
                        expectedClose: forecast.expectedClose, lowerClose: forecast.lowerClose,
                        upperClose: forecast.upperClose, riseProbability: forecast.riseProbability,
                        observations: forecast.observations, evidence: evidence)
                    guard evidence.isValid(for: record) else {
                        nextReasons[stock.id] = L10n.t("Daily-candle evidence is inconsistent. Waiting for valid data.")
                        completedCloses[stock.id] = nil
                        continue
                    }
                    next[stock.id] = forecast
                    nextCandidates.append(record)
                } else {
                    nextReasons[stock.id] = L10n.t("At least 20 completed daily returns are required.")
                }
            }
            try checkCurrentSettings()
            forecasts = next
            candidates = nextCandidates
            retainCloseHistory(nextCandidates, now: suppliedNow ?? Date())
            if preferences.recordsStockForecasts {
                let scheduled = nextCandidates.map { record in
                    var record = record
                    record.capture = .scheduled
                    return record
                }
                journal.record(scheduled)
            }
            reasons = nextReasons
            message = nil
        } catch is CancellationError {
            return
        } catch {
            // A cancelled request must not clear results from the replacement watchlist/account refresh.
            guard (try? checkCurrentSettings()) != nil else { return }
            forecasts = [:]
            candidates = []
            if let failure = error as? TossInvestAPI.Failure, case .http(429) = failure {
                message = L10n.t("Toss Securities rate limit reached. Retrying soon.")
            } else {
                message = L10n.t("Could not load stock estimates. Check API keys and allowed IP.")
            }
        }
    }

    private func clearHoldings() {
        holdings = []
        forecasts = [:]
        candidates = []
        reasons = [:]
        holdingsAt = nil
        completedCloses = [:]
        historySession = [:]
        historyAttempt = [:]
    }
}
