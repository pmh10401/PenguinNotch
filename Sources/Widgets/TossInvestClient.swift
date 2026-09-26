import Combine
import Foundation
import Security

/// Client id and secret for the Toss Securities Open API. The secret never
/// goes into UserDefaults; both values live in the login keychain.
enum TossCredentials {
    static let service = "com.pmh10401.penguinnotch.tossinvest"
    private static let previousService = "com.vinz.codenotch.tossinvest"
    private static let migratedLegacyItems = migrateLegacyItems(from: previousService, to: service)
    private static let cache = CredentialCache<(clientID: String, clientSecret: String)> { _ in false }

    static func load() -> (clientID: String, clientSecret: String) {
        _ = migratedLegacyItems
        return (try? cache.value { (read("client-id"), read("client-secret")) }) ?? ("", "")
    }

    private static func read(_ account: String) -> String {
        // A refused read of a new item must not fall back to an older copy.
        let selected = KeychainItem.newest(service: service, account: account) == nil
            ? previousService : service
        return KeychainItem.read(service: selected, account: account) ?? ""
    }

    static var hasSecret: Bool { !(load().clientSecret.isEmpty) }

    /// An empty secret leaves the stored secret in place, so saving a corrected
    /// client id does not wipe a key the field is no longer showing.
    static func save(clientID: String, clientSecret: String) {
        _ = migratedLegacyItems
        defer { cache.forget() }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            KeychainItem.delete(service: service, account: "client-id")
            KeychainItem.delete(service: previousService, account: "client-id")
        } else {
            _ = KeychainItem.store(service: service, account: "client-id", value: id)
        }
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        _ = KeychainItem.store(service: service, account: "client-secret", value: secret)
    }

    static func clear() {
        defer { cache.forget() }
        KeychainItem.delete(service: service, account: "client-id")
        KeychainItem.delete(service: service, account: "client-secret")
        KeychainItem.delete(service: previousService, account: "client-id")
        KeychainItem.delete(service: previousService, account: "client-secret")
    }

    /// Rename existing items in place so the Keychain prompt shows this app's
    /// name. The secret never leaves the Keychain during the migration.
    static func migrateLegacyItems(from oldService: String, to newService: String) {
        for account in ["client-id", "client-secret"] {
            guard KeychainItem.newest(service: newService, account: account) == nil else { continue }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: oldService,
                kSecAttrAccount: account
            ]
            let changes: [CFString: Any] = [
                kSecAttrService: newService,
                kSecAttrLabel: "PenguinNotch Stocks"
            ]
            _ = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        }
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

    static func regularSession(token: String, market: WatchedStock.Market, at now: Date = Date(),
                               session: URLSession = .shared) async throws -> TradingSession? {
        var request = URLRequest(url: base.appending(path: "/api/v1/market-calendar/\(market.rawValue.uppercased())"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let calendar = try decoder.decode(TossResult<MarketSessions>.self, from: await body(for: request, session: session)).result
        return [calendar.today, calendar.previousBusinessDay].compactMap { $0.regular(market: market) }
            .first { $0.contains(now) }
    }

    static func forecastCloses(token: String, stock: WatchedStock, session: URLSession = .shared) async throws -> [(date: Date, close: Decimal)] {
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 64, session: session)
        return StockQuoteCodec.dailyCloses(from: data)
    }

    /// Historical scoring must retain the price units observed on the prediction date.
    /// Later splits/dividends must not retroactively adjust the recorded target price.
    static func recordedClose(token: String, stock: WatchedStock, sessionEnd: Date,
                              session: URLSession = .shared) async throws -> [(date: Date, close: Decimal)] {
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 2,
                                        before: sessionEnd, adjusted: false, session: session)
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
        let data = try await candleData(token: token, symbol: stock.symbol, interval: "1d", count: 3,
                                        session: session)
        return StockQuoteCodec.previousClose(closes: StockQuoteCodec.dailyCloses(from: data),
                                             priceTime: priceTime,
                                             timeZone: StockQuoteCodec.timeZone(for: stock.market))
    }

    static func chartCandles(token: String, stock: WatchedStock, interval: StockChartInterval,
                             session: URLSession = .shared) async throws -> [StockCandle] {
        let daily = interval == .day
        let data = try await candleData(token: token, symbol: stock.symbol,
                                        interval: daily ? "1d" : "1m", count: daily ? 20 : 200,
                                        session: session)
        guard let candles = StockQuoteCodec.candles(from: data) else { throw Failure.invalidResponse }
        return candles.sorted { $0.end < $1.end }
    }

    private static func candleData(token: String, symbol: String, interval: String, count: Int,
                                   before: Date? = nil, adjusted: Bool? = nil,
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
            components.queryItems?.append(URLQueryItem(name: "before", value: ISO8601DateFormatter().string(from: before)))
        }
        if let adjusted {
            components.queryItems?.append(URLQueryItem(name: "adjusted", value: adjusted ? "true" : "false"))
        }
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
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
        var request = URLRequest(url: url)
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

    init(preferences: Preferences) {
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
                let credentials = TossCredentials.load()
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
        var delay: Double = 1
        while !Task.isCancelled, generation == token {
            do {
                let access = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                                  clientSecret: credentials.clientSecret)
                let symbolsOnly = symbols.map(\.symbol)
                async let fetchedNames = TossInvestAPI.names(token: access.value, symbols: symbolsOnly)
                let prices = try await TossInvestAPI.prices(token: access.value, symbols: symbolsOnly)
                guard generation == token else { return }
                quotes.merge(prices) { _, new in new }
                publish()
                let resolvedNames = (try? await fetchedNames) ?? [:]
                guard generation == token else { return }
                names.merge(resolvedNames) { _, new in new }
                link = .live
                publish()
                // Daily candles are per-symbol; let trades start while rings fill in.
                let candles = Task {
                    for stock in symbols {
                        guard generation == token, !Task.isCancelled else { return }
                        let priceTime = quotes[stock.id]?.timestamp ?? Date()
                        if let close = try? await TossInvestAPI.previousClose(token: access.value, stock: stock, priceTime: priceTime) {
                            guard generation == token, !Task.isCancelled else { return }
                            closes[stock.id] = close
                            publish()
                        }
                    }
                }
                defer { candles.cancel() }
                try await TossInvestAPI.stream(token: access.value, stocks: symbols) { [weak self] event in
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

    private func absorb(_ event: TossSocketEvent) {
        switch event {
        case .tick(let id, let tick):
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
            return StockBoard.snapshot(stock: stock, quote: quotes[stock.id], previousClose: closes[stock.id],
                                       name: names[stock.id], link: link, source: source)
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
