import Combine
import Foundation
import Security

/// The Toss pair is one Keychain item, so a changed signing identity needs
/// one authorization for the pair. Background callers never ask for a password.
enum TossCredentials {
    static let service = "com.pmh10401.penguinnotch.tossinvest"
    private static let store = TossCredentialStore(
        service: service, previousService: "com.vinz.codenotch.tossinvest",
        read: KeychainItem.readData,
        write: { KeychainItem.store(service: $0, account: $1, value: $2, interactive: $3) },
        remove: { KeychainItem.delete(service: $0, account: $1, interactive: $2) })

    static func load() -> (clientID: String, clientSecret: String) {
        guard let value = try? store.load() else { return ("", "") }
        return (value.clientID, value.clientSecret)
    }

    /// Called only by the user's Allow access button, never by a refresh.
    static func authorize() -> Bool { (try? store.authorize()) != nil }
    static var hasSecret: Bool { !(load().clientSecret.isEmpty) }

    @discardableResult
    static func save(clientID: String, clientSecret: String) -> Bool {
        store.save(clientID: clientID, clientSecret: clientSecret)
    }

    @discardableResult
    static func clear() -> Bool { store.clear() }
}

/// The native operations are injected so preservation and refusal paths can
/// run offline without reading or modifying a person's Keychain.
final class TossCredentialStore: @unchecked Sendable {
    struct Credentials: Codable {
        let version: Int
        let clientID: String
        let clientSecret: String
        init(clientID: String, clientSecret: String) {
            version = 1; self.clientID = clientID; self.clientSecret = clientSecret
        }
    }
    enum Failure: Error { case keychain(OSStatus), invalid, pending }
    private let service: String
    private let previousService: String
    private let read: (String, String, Bool) -> (OSStatus, Data?)
    private let write: (String, String, String, Bool) -> Bool
    private let remove: (String, String, Bool) -> Bool
    private let cache = CredentialCache<Credentials> { _ in false }
    private let prompt = PromptPermission()
    // Serialize migration and settings writes so an old pair cannot overwrite
    // a freshly saved pair. Background reads return while an unlock is pending.
    private let operationLock = NSLock()

    init(service: String, previousService: String,
         read: @escaping (String, String, Bool) -> (OSStatus, Data?),
         write: @escaping (String, String, String, Bool) -> Bool,
         remove: @escaping (String, String, Bool) -> Bool) {
        self.service = service; self.previousService = previousService
        self.read = read; self.write = write; self.remove = remove
    }

    func load() throws -> Credentials {
        guard operationLock.try() else { throw Failure.pending }
        defer { operationLock.unlock() }
        return try loadUnlocked()
    }

    func authorize() throws -> Credentials {
        operationLock.lock()
        defer { operationLock.unlock() }
        prompt.grant()
        cache.forget()
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> Credentials {
        try cache.value {
            let interactive = prompt.take()
            let (status, data) = read(service, "credentials", interactive)
            if status == errSecSuccess {
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys) == ["version", "clientID", "clientSecret"],
                      let value = try? JSONDecoder().decode(Credentials.self, from: data),
                      value.version == 1, !value.clientID.isEmpty, !value.clientSecret.isEmpty else {
                    throw Failure.invalid
                }
                return value
            }
            guard status == errSecItemNotFound else { throw Failure.keychain(status) }

            // Only an absent item permits fallback. Refusal, corrupt data or
            // another OS error must never resurrect a different stored pair.
            func legacy(_ account: String) throws -> String {
                var result = read(service, account, interactive)
                if result.0 == errSecItemNotFound { result = read(previousService, account, interactive) }
                guard result.0 == errSecSuccess else { throw Failure.keychain(result.0) }
                guard let data = result.1, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                    throw Failure.invalid
                }
                return value
            }
            let value = try Credentials(clientID: legacy("client-id"), clientSecret: legacy("client-secret"))
            // Add the complete pair atomically. Never rename/delete old items
            // or show another dialog for a background migration write.
            guard persist(value, interactive: false) else { throw Failure.keychain(errSecNotAvailable) }
            return value
        }
    }

    func save(clientID: String, clientSecret: String) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        let savedSecret: String
        if secret.isEmpty {
            guard let saved = try? loadUnlocked() else { return false }
            savedSecret = saved.clientSecret
        } else { savedSecret = secret }
        guard persist(Credentials(clientID: id, clientSecret: savedSecret), interactive: true) else { return false }
        cache.forget()
        return true
    }

    private func persist(_ value: Credentials, interactive: Bool) -> Bool {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return false }
        return write(service, "credentials", json, interactive)
    }

    func clear() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        // Remove legacy copies first so a partial failure cannot remove the
        // authoritative bundle then restore old keys on the next refresh.
        for name in [service, previousService] {
            for account in ["client-id", "client-secret"] {
                guard remove(name, account, true) else { return false }
            }
        }
        guard remove(service, "credentials", true) else { return false }
        cache.forget()
        return true
    }
}

enum TossInvestAPI {
    static let base = URL(string: "https://openapi.tossinvest.com")!
    static let socket = URL(string: "wss://openapi-ws.tossinvest.com/ws/v1")!

    @MainActor private static var tokenCredentials: (clientID: String, clientSecret: String)?
    @MainActor private static var cachedToken: AccessToken?
    @MainActor private static var tokenTask: Task<AccessToken, Error>?
    @MainActor private static var tokenGeneration = UUID()

    enum Failure: Error { case invalidResponse, http(Int) }

    struct AccessToken {
        var value: String
        var expiresAt: Date
    }

    @MainActor
    static func accessToken(clientID: String, clientSecret: String, now: Date = Date(),
                            session: URLSession = .shared) async throws -> AccessToken {
        if tokenCredentials?.clientID != clientID || tokenCredentials?.clientSecret != clientSecret {
            tokenTask?.cancel()
            tokenTask = nil
            cachedToken = nil
            tokenCredentials = (clientID, clientSecret)
            tokenGeneration = UUID()
        }
        if let cachedToken, cachedToken.expiresAt > now { return cachedToken }
        if let tokenTask { return try await tokenTask.value }
        let generation = tokenGeneration
        let task = Task { try await requestAccessToken(clientID: clientID, clientSecret: clientSecret,
                                                        now: now, session: session) }
        tokenTask = task
        do {
            let token = try await task.value
            guard generation == tokenGeneration else { throw CancellationError() }
            cachedToken = token
            tokenTask = nil
            return token
        } catch {
            if generation == tokenGeneration { tokenTask = nil }
            throw error
        }
    }

    private static func requestAccessToken(clientID: String, clientSecret: String, now: Date,
                                           session: URLSession) async throws -> AccessToken {
        var request = URLRequest(url: base.appending(path: "/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data = try await body(for: request, session: session)
        guard let token = StockQuoteCodec.token(from: data) else { throw Failure.invalidResponse }
        return AccessToken(value: token.accessToken, expiresAt: now.addingTimeInterval(max(token.expiresIn - 60, 30)))
    }

    @MainActor private static func invalidate(_ token: String) {
        if cachedToken?.value == token { cachedToken = nil }
    }

    static func prices(token: String, symbols: [String], session: URLSession = .shared) async throws -> [String: StockTick] {
        let data = try await authorized(path: "/api/v1/prices", token: token, symbols: symbols, session: session)
        return StockQuoteCodec.prices(from: data)
    }

    /// Forecasts require an actual trade timestamp; the regular quote UI can
    /// still show a price when the API leaves its nullable timestamp empty.
    static func timestampedPrices(token: String, symbols: [String], session: URLSession = .shared) async throws -> [String: StockTick] {
        let data = try await authorized(path: "/api/v1/prices", token: token, symbols: symbols, session: session)
        return StockQuoteCodec.prices(from: data, requireTimestamp: true)
    }

    static func accounts(token: String, session: URLSession = .shared) async throws -> [TossAccount] {
        var request = URLRequest(url: base.appending(path: "/api/v1/accounts"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try JSONDecoder().decode(TossResult<[TossAccount]>.self, from: await body(for: request, session: session)).result
    }

    static func holdings(token: String, accountSeq: Int, session: URLSession = .shared) async throws -> [PortfolioHolding] {
        var request = URLRequest(url: base.appending(path: "/api/v1/holdings"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(accountSeq), forHTTPHeaderField: "X-Tossinvest-Account")
        return try JSONDecoder().decode(TossResult<PortfolioHoldings>.self, from: await body(for: request, session: session)).result.items
    }

    static func accountPortfolio(token: String, accountSeq: Int, session: URLSession = .shared) async throws -> TossAccountPortfolio {
        guard accountSeq > 0, accountSeq <= 9_007_199_254_740_991 else { throw Failure.invalidResponse }
        var request = URLRequest(url: base.appending(path: "/api/v1/holdings"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(accountSeq), forHTTPHeaderField: "X-Tossinvest-Account")
        return try TossAccountPortfolio.decode(await body(for: request, session: session))
    }

    static func regularSession(token: String, market: WatchedStock.Market, at now: Date = Date(),
                               session: URLSession = .shared) async throws -> TradingSession? {
        let calendar = try await marketSessions(token: token, market: market, at: now, session: session)
        return [calendar.today, calendar.previousBusinessDay, calendar.nextBusinessDay].compactMap { $0?.regular(market: market) }
            .first { $0.contains(now) }
    }

    /// Public market data also serves watch quotes when forecasts are disabled.
    static func marketSessions(token: String, market: WatchedStock.Market, at now: Date = Date(),
                                session: URLSession = .shared) async throws -> MarketSessions {
        var components = URLComponents(url: base.appending(path: "/api/v1/market-calendar/\(market.rawValue.uppercased())"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date", value: StockQuoteCodec.marketDate(now, market: market))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TossResult<MarketSessions>.self, from: await body(for: request, session: session)).result
    }

    static func forecastCloses(token: String, stock: WatchedStock, session: URLSession = .shared) async throws -> [(date: Date, close: Decimal)] {
        // Pin the documented default so the archived evidence retains known price units.
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 64,
                                        adjusted: true, session: session)
        return StockQuoteCodec.dailyCloses(from: data)
    }

    /// Historical scoring must retain the price units observed on the prediction date.
    /// Later splits/dividends must not retroactively adjust the recorded target price.
    static func recordedClose(token: String, stock: WatchedStock, sessionEnd: Date,
                              session: URLSession = .shared) async throws -> [(date: Date, close: Decimal)] {
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 2,
                                        before: ISO8601DateFormatter().string(from: sessionEnd), adjusted: false, session: session)
        return StockQuoteCodec.dailyCloses(from: data)
    }

    static func names(token: String, symbols: [String], session: URLSession = .shared) async throws -> [String: String] {
        let data = try await authorized(path: "/api/v1/stocks", token: token, symbols: symbols, session: session)
        return StockQuoteCodec.names(from: data)
    }

    /// The close before the session that owns `priceTime`. A daily candle can
    /// already be dated after the latest quote, so keep one extra older bar.
    static func previousClose(token: String, stock: WatchedStock, priceTime: Date,
                              session: URLSession = .shared) async throws -> Decimal? {
        let daily = try await quoteCloses(token: token, stock: stock, session: session)
        return StockQuoteCodec.previousClose(closes: daily.values, priceTime: priceTime,
                                             timeZone: StockQuoteCodec.timeZone(for: stock.market))
    }

    static func quoteCloses(token: String, stock: WatchedStock,
                            session: URLSession = .shared) async throws -> StockDailyCloses {
        let requestedAt = Date()
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 3,
                                        adjusted: true, session: session)
        return StockDailyCloses(values: StockQuoteCodec.dailyCloses(from: data), requestedAt: requestedAt)
    }

    static func chartCandles(token: String, stock: WatchedStock, interval: StockChartInterval,
                             session: URLSession = .shared) async throws -> [StockCandle] {
        // 120-bar SMA needs history before the 20 visible bars. Ten-minute bars use raw minutes.
        // ponytail: bounded backfill per refresh; add incremental history only if this becomes costly.
        var candles: [Date: StockCandle] = [:]
        var before: String?
        for page in 0..<(interval == .tenMinutes ? 8 : 1) {
            try Task.checkCancellation()
            if page > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let data = try await candleData(token: token, symbol: stock.symbol,
                interval: interval == .day ? "1d" : "1m", count: 200, before: before,
                adjusted: true, session: session)
            guard let rows = StockQuoteCodec.candles(from: data) else { throw Failure.invalidResponse }
            let oldCount = candles.count
            // `before` is inclusive. Keep the first observation when page boundaries overlap.
            for candle in rows where candles[candle.end] == nil { candles[candle.end] = candle }
            if interval != .tenMinutes || candles.count >= 1_400 || rows.isEmpty { break }
            guard candles.count > oldCount,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any] else { throw Failure.invalidResponse }
            guard let cursor = result["nextBefore"], !(cursor is NSNull) else { break }
            guard let next = cursor as? String, !next.isEmpty, next != before else { throw Failure.invalidResponse }
            before = next
        }
        return candles.values.sorted { $0.end < $1.end }
    }

    /// A single bounded public page; strict decoding retains inclusive duplicates for the collector.
    static func backtestPage(token: String, stock: WatchedStock, interval: String, before: String,
                             session: URLSession = .shared) async throws -> StockBacktestReply {
        guard ["1m", "1d"].contains(interval), let bound = StockBacktestStore.timestamp(before),
              WatchedStock.parse(stock.id) == stock else { throw Failure.invalidResponse }
        let requestedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let data = try await candleData(token: token, symbol: stock.symbol, interval: interval, count: 200,
                                       before: before, adjusted: true, session: session)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any], let raw = result["candles"] as? [[String: Any]],
              raw.allSatisfy({ row in
                  (row["timestamp"] as? String).map(StockBacktest.cursor) == true
                    && ["openPrice", "highPrice", "lowPrice", "closePrice", "volume"].allSatisfy { key in
                        if let text = row[key] as? String { return Double(text)?.isFinite == true }
                        if let number = row[key] as? NSNumber { return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite }
                        return false
                    }
              }),
              let values = StockQuoteCodec.candles(from: data),
              let next = result["nextBefore"], next is NSNull || (next as? String).map(StockBacktest.cursor) == true else { throw Failure.invalidResponse }
        try StockBacktestStore.validate(values, before: bound)
        return .candles(values: values, nextBefore: next as? String, requestedAt: requestedAt)
    }

    private static func candleData(token: String, symbol: String, interval: String, count: Int,
                                   before: String? = nil, adjusted: Bool? = nil,
                                   session: URLSession) async throws -> Data {
        guard var components = URLComponents(url: base.appending(path: "/api/v1/candles"), resolvingAgainstBaseURL: false) else {
            throw Failure.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "count", value: String(count))
        ]
        if let before {
            components.queryItems?.append(URLQueryItem(name: "before", value: before))
        }
        if let adjusted {
            components.queryItems?.append(URLQueryItem(name: "adjusted", value: adjusted ? "true" : "false"))
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await body(for: request, session: session)
    }

    /// Holds the socket open, forwarding frames until the server or the task ends.
    static func stream(token: String, stocks: [WatchedStock],
                       onEvent: @escaping @MainActor (TossSocketEvent) -> Void) async throws {
        var request = URLRequest(url: socket)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socketTask = URLSession.shared.webSocketTask(with: request)
        socketTask.resume()
        let ping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                try? await socketTask.send(.string("PING"))
            }
        }
        defer {
            ping.cancel()
            socketTask.cancel(with: .normalClosure, reason: nil)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await socketTask.send(.string(StockQuoteCodec.subscriptionJSON(stocks)))
            while !Task.isCancelled {
                let message = try await socketTask.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let value): text = String(decoding: value, as: UTF8.self)
                @unknown default: continue
                }
                if let event = StockQuoteCodec.event(from: text) {
                    await onEvent(event)
                }
            }
        } onCancel: {
            socketTask.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func authorized(path: String, token: String, symbols: [String],
                                   session: URLSession) async throws -> Data {
        guard var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw Failure.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await body(for: request, session: session)
    }

    private static func body(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401,
               let authorization = request.value(forHTTPHeaderField: "Authorization"),
               authorization.hasPrefix("Bearer ") {
                await invalidate(String(authorization.dropFirst("Bearer ".count)))
            }
            throw Failure.http(http.statusCode)
        }
        return data
    }
}

/// One cell for the registered symbols. Quotes start from REST, then each
/// trade on the Toss Securities socket replaces that symbol's price.
@MainActor
final class StockQuotesMonitor: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    private var quotes: [String: StockTick] = [:]
    private var dailyCloses: [String: StockDailyCloses] = [:]
    private var usCalendar: MarketSessions?
    // Finnhub supplies its own previous close; preserve that provider's semantics.
    private var closes: [String: Decimal] = [:]
    private var names: [String: String] = [:]
    private var link: StockLink = .idle
    private var stockLinks: [String: StockLink] = [:]
    private var enabled = false
    private var stocks: [WatchedStock] = []
    private var source: StockQuoteSource = .toss
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession
    private let loadCredentials: () -> (clientID: String, clientSecret: String)
    private let stream: (String, [WatchedStock], @escaping @MainActor (TossSocketEvent) -> Void) async throws -> Void
    private let pollInterval: TimeInterval

    init(preferences: Preferences, session: URLSession = .shared,
         loadCredentials: @escaping () -> (clientID: String, clientSecret: String) = TossCredentials.load,
         stream: @escaping (String, [WatchedStock], @escaping @MainActor (TossSocketEvent) -> Void) async throws -> Void = TossInvestAPI.stream,
         pollInterval: TimeInterval = 60) {
        self.session = session
        self.loadCredentials = loadCredentials
        self.stream = stream
        self.pollInterval = pollInterval
        preferences.$showsStocks.combineLatest(preferences.$stockSymbols, preferences.$stockSettingsRevision)
            .sink { [weak self] shows, symbols, _ in
                self?.restart(shows: shows, symbols: WatchedStock.parseList(symbols),
                              source: preferences.stockQuoteSource)
            }
            .store(in: &cancellables)
    }

    func stop() {
        task?.cancel()
        task = nil
        generation = UUID()
        cancellables.removeAll()
    }

    func refresh() { restart(shows: enabled, symbols: stocks, source: source) }

    private func restart(shows: Bool, symbols: [WatchedStock], source: StockQuoteSource) {
        task?.cancel()
        task = nil
        generation = UUID()
        if self.source != source {
            quotes.removeAll()
            closes.removeAll()
            names.removeAll()
            self.source = source
        }
        dailyCloses.removeAll()
        usCalendar = nil
        enabled = shows
        stocks = symbols
        let ids = Set(symbols.map(\.id))
        quotes = quotes.filter { ids.contains($0.key) }
        closes = closes.filter { ids.contains($0.key) }
        stockLinks = [:]
        guard shows else {
            snapshots = []
            return
        }
        guard !symbols.isEmpty else {
            snapshots = [StockBoard.placeholder(message: L10n.t("Add a stock symbol in Settings → Stocks."), source: source)]
            return
        }
        let supported = symbols.filter { source.supports($0) }
        for stock in symbols where !source.supports(stock) {
            stockLinks[stock.id] = .failed(L10n.t("Finnhub supports US quotes only. Select Toss Securities for Korean stocks."))
        }
        link = .idle
        let token = generation
        if !supported.isEmpty {
            switch source {
            case .toss:
                let credentials = loadCredentials()
                if credentials.clientID.isEmpty || credentials.clientSecret.isEmpty {
                    link = .failed(L10n.t("Add Toss Securities API keys in Settings → Stocks."))
                } else {
                    task = Task { [weak self] in
                        await self?.run(supported, credentials: credentials, generation: token)
                    }
                }
            case .finnhub:
                let key = FinnhubCredentials.load()
                if key.isEmpty {
                    link = .failed(L10n.t("Add a Finnhub API key in Settings → Stocks."))
                } else {
                    task = Task { [weak self] in
                        await self?.runFinnhub(supported, key: key, generation: token)
                    }
                }
            }
        }
        publish()
    }

    private func run(_ symbols: [WatchedStock], credentials: (clientID: String, clientSecret: String),
                     generation token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        // The socket supplies trades, not session rollover or final
        // regular closes. Keep REST/calendar/daily data fresh beside it.
        let polling = Task {
            while generation == token, !Task.isCancelled {
                let startedAt = Date()
                do {
                    let current = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                                      clientSecret: credentials.clientSecret, session: session)
                    guard generation == token, !Task.isCancelled else { return }
                    await refreshToss(symbols, accessToken: current.value, generation: token)
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    link = .reconnecting
                    publish()
                }
                try? await Task.sleep(for: .seconds(max(1, pollInterval - Date().timeIntervalSince(startedAt))))
            }
        }
        defer { polling.cancel() }
        var delay: Double = 1
        while !Task.isCancelled, generation == token {
            do {
                let access = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                                  clientSecret: credentials.clientSecret, session: session)
                let resolvedNames = (try? await TossInvestAPI.names(token: access.value, symbols: symbols.map(\.symbol), session: session)) ?? [:]
                guard generation == token, !Task.isCancelled else { return }
                names.merge(resolvedNames) { _, new in new }
                publish()
                try await stream(access.value, symbols) { [weak self] event in
                    guard let self, self.generation == token else { return }
                    self.absorb(event)
                }
                guard generation == token, !Task.isCancelled else { return }
                delay = 1
                link = .reconnecting
            } catch let error as TossInvestAPI.Failure {
                guard generation == token else { return }
                link = .failed(message(for: error))
                publish()
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                link = .reconnecting
                publish()
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func refreshToss(_ symbols: [WatchedStock], accessToken: String, generation token: UUID) async {
        async let fetchedPrices = TossInvestAPI.prices(token: accessToken, symbols: symbols.map(\.symbol), session: session)
        if symbols.contains(where: { $0.market == .us }) {
            var calendar = usCalendar
            do {
                calendar = try await TossInvestAPI.marketSessions(token: accessToken, market: .us, session: session)
            } catch is DecodingError {
                calendar = nil
            } catch {
                // Keep the last official intervals through a failed request.
                // usSession still requires them to contain the actual trade.
            }
            guard generation == token, !Task.isCancelled else { return }
            usCalendar = calendar
        }
        do {
            let prices = try await fetchedPrices
            guard generation == token, !Task.isCancelled else { return }
            for (id, tick) in prices where StockQuoteCodec.accepts(tick, replacing: quotes[id], now: Date()) {
                quotes[id] = tick
            }
            link = .live
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            link = .reconnecting
        }
        publish()
        for stock in symbols {
            guard generation == token, !Task.isCancelled else { return }
            let daily = try? await TossInvestAPI.quoteCloses(token: accessToken, stock: stock, session: session)
            guard generation == token, !Task.isCancelled else { return }
            if let daily { dailyCloses[stock.id] = daily }
            publish()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func absorb(_ event: TossSocketEvent) {
        switch event {
        case .tick(let id, let tick):
            guard stocks.contains(where: { $0.id == id }),
                  StockQuoteCodec.accepts(tick, replacing: quotes[id], now: Date()) else { return }
            quotes[id] = tick
            link = .live
        case .subscribed:
            link = .live
        case .rejected, .pong:
            break
        case .failure:
            link = .reconnecting
        }
        publish()
    }

    private func runFinnhub(_ symbols: [WatchedStock], key: String, generation token: UUID) async {
        while !Task.isCancelled, generation == token {
            var limited = false
            for stock in symbols {
                guard !Task.isCancelled, generation == token else { return }
                do {
                    let (tick, previous) = try await FinnhubAPI.quote(symbol: stock.symbol, key: key)
                    guard !Task.isCancelled, generation == token else { return }
                    quotes[stock.id] = tick
                    closes[stock.id] = previous
                    stockLinks[stock.id] = nil
                    link = .live
                } catch let error as FinnhubAPI.Failure {
                    guard !Task.isCancelled, generation == token else { return }
                    switch error {
                    case .http(401), .http(403):
                        link = .failed(L10n.t("Finnhub refused the API key."))
                        limited = true
                    case .http(429):
                        link = .failed(L10n.t("Finnhub rate limit reached. Retrying later."))
                        limited = true
                    default:
                        stockLinks[stock.id] = .failed(L10n.t("Finnhub quote unavailable."))
                    }
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    stockLinks[stock.id] = .failed(L10n.t("Finnhub quote unavailable."))
                }
                publish()
                if limited { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(limited ? 120 : 60))
        }
    }

    private func publish() {
        let next = stocks.map { stock in
            let link = stockLinks[stock.id] ?? self.link
            let quote = quotes[stock.id]
            let session = quote.flatMap { $0.hasTimestamp ? StockQuoteCodec.usSession(at: $0.timestamp, calendar: usCalendar) : nil }
            let basis = quote.flatMap { StockQuoteCodec.changeBasis(daily: dailyCloses[stock.id], quote: $0,
                                                                     market: stock.market, session: session) }
            return StockBoard.snapshot(stock: stock, quote: quote,
                                       previousClose: source == .finnhub ? closes[stock.id] : basis?.close,
                                       name: names[stock.id], link: link, source: source,
                                       quoteSession: session, basisDate: basis?.date)
        }
        if next != snapshots { snapshots = next }
    }

    private func message(for error: TossInvestAPI.Failure) -> String {
        switch error {
        case .http(401), .http(403):
            return L10n.t("Toss Securities refused this connection. Check the API keys and the allowed IP.")
        default:
            return L10n.t("Toss Securities is unavailable. It will retry automatically.")
        }
    }
}
