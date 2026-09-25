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

struct MarketSessions: Decodable {
    let today: MarketSessionDay
    let previousBusinessDay: MarketSessionDay
}

struct MarketSessionDay: Decodable {
    let integrated: IntegratedMarket?
    let regularMarket: TradingSession?

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

/// Zero-drift lognormal continuation. The current quote is the conditional
/// expected close; daily close-to-close variance only sizes the remaining risk.
/// These are model probabilities, not calibrated forecasts or trading signals.
struct StockForecast {
    let riseProbability: Double
    let expectedClose: Decimal
    let observations: Int

    static func estimate(price: Decimal, completedCloses: [Decimal],
                         trading: TradingSession, now: Date) -> StockForecast? {
        guard trading.contains(now), trading.duration > 0, price > 0,
              completedCloses.count >= 21,
              let previous = completedCloses.first, previous > 0 else { return nil }
        let values = completedCloses.map { NSDecimalNumber(decimal: $0).doubleValue }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let returns = zip(values, values.dropFirst()).map { log($0.0 / $0.1) }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
        let remaining = trading.endTime.timeIntervalSince(now) / trading.duration
        let sigma = sqrt(variance * remaining)
        guard sigma.isFinite, sigma > 0 else { return nil }
        let logMove = log(NSDecimalNumber(decimal: price / previous).doubleValue)
        let z = (logMove - variance * remaining / 2) / sigma
        guard z.isFinite else { return nil }
        let probability = min(max(0.5 * (1 + erf(z / sqrt(2))), 0), 1)
        return StockForecast(riseProbability: probability, expectedClose: price,
                             observations: returns.count)
    }
}

/// Account numbers and positions remain in memory. The selected account's
/// opaque sequence is a preference; reads run only while this pane is visible.
@MainActor
final class StockForecastStore: ObservableObject {
    private let privateSession = URLSession(configuration: .ephemeral)
    @Published private(set) var accounts: [TossAccount] = []
    @Published private(set) var holdings: [PortfolioHolding] = []
    @Published private(set) var forecasts: [String: StockForecast] = [:]
    @Published private(set) var reasons: [String: String] = [:]
    @Published private(set) var message: String?
    @Published private(set) var loading = false

    private var accountSeq = 0
    private var holdingsAt: Date?
    private var completedCloses: [String: [Decimal]] = [:]
    private var historySession: [String: Date] = [:]
    private var historyAttempt: [String: Date] = [:]

    func clear() {
        accounts = []
        holdings = []
        forecasts = [:]
        reasons = [:]
        message = nil
        loading = false
        accountSeq = 0
        holdingsAt = nil
        completedCloses = [:]
        historySession = [:]
        historyAttempt = [:]
    }

    func clearSelection() {
        clearHoldings()
        accountSeq = 0
    }

    func refresh(preferences: Preferences, session suppliedSession: URLSession? = nil, now: Date = Date(),
                 credentials supplied: (clientID: String, clientSecret: String)? = nil) async {
        guard preferences.portfolioForecastEnabled, preferences.stockQuoteSource == .toss else { clear(); return }
        let session = suppliedSession ?? privateSession
        let credentials = supplied ?? TossCredentials.load()
        guard !credentials.clientID.isEmpty, !credentials.clientSecret.isEmpty else {
            message = L10n.t("Save Toss Securities API keys to view account holdings.")
            return
        }
        loading = holdings.isEmpty
        defer { loading = false }
        do {
            let token = try await TossInvestAPI.accessToken(clientID: credentials.clientID,
                                                             clientSecret: credentials.clientSecret,
                                                             session: session)
            if accounts.isEmpty {
                accounts = try await TossInvestAPI.accounts(token: token.value, session: session)
                    .filter { $0.accountType == "BROKERAGE" }
            }
            try Task.checkCancellation()
            guard !accounts.isEmpty else {
                message = L10n.t("No supported Toss Securities account was found.")
                return
            }
            if preferences.tossAccountSeq == 0, accounts.count == 1 {
                preferences.tossAccountSeq = accounts[0].accountSeq
            }
            guard accounts.contains(where: { $0.accountSeq == preferences.tossAccountSeq }) else {
                clearHoldings()
                message = L10n.t("Select an account to view its holdings.")
                return
            }
            let selected = preferences.tossAccountSeq
            if accountSeq != selected {
                clearHoldings()
                accountSeq = selected
            }
            if holdingsAt == nil || now.timeIntervalSince(holdingsAt!) >= 300 {
                let fetched = try await TossInvestAPI.holdings(token: token.value, accountSeq: selected, session: session)
                try Task.checkCancellation()
                holdings = fetched
                holdingsAt = now
            }
            guard !holdings.isEmpty else {
                forecasts = [:]
                reasons = [:]
                message = L10n.t("This account has no supported stock holdings.")
                return
            }

            var sessions: [WatchedStock.Market: TradingSession] = [:]
            for market in [WatchedStock.Market.kr, .us]
            where holdings.contains(where: { $0.stock?.market == market }) {
                if let trading = try await TossInvestAPI.regularSession(token: token.value, market: market,
                                                                         at: now, session: session) {
                    sessions[market] = trading
                }
            }
            try Task.checkCancellation()
            let active = holdings.compactMap(\.stock).filter { sessions[$0.market] != nil }
            var quotes: [String: StockTick] = [:]
            for offset in stride(from: 0, to: active.count, by: 200) {
                let batch = Array(active[offset..<min(offset + 200, active.count)])
                quotes.merge(try await TossInvestAPI.timestampedPrices(token: token.value,
                                                                        symbols: batch.map(\.symbol), session: session)) { _, new in new }
            }
            try Task.checkCancellation()
            var next: [String: StockForecast] = [:]
            var nextReasons: [String: String] = [:]
            for holding in holdings {
                guard let stock = holding.stock else {
                    nextReasons[holding.id] = L10n.t("This asset cannot be estimated.")
                    continue
                }
                guard let trading = sessions[stock.market] else {
                    nextReasons[holding.id] = L10n.t("Regular market is closed.")
                    continue
                }
                guard let quote = quotes[stock.id], quote.price > 0,
                      trading.contains(quote.timestamp),
                      now.timeIntervalSince(quote.timestamp) >= -60,
                      now.timeIntervalSince(quote.timestamp) <= 600 else {
                    nextReasons[holding.id] = L10n.t("No recent trade price is available.")
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
                            .map(\.close)
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(60)) // below the chart endpoint's 20/s limit
                }
                if let forecast = StockForecast.estimate(price: quote.price,
                                                           completedCloses: completedCloses[stock.id] ?? [],
                                                           trading: trading, now: now) {
                    next[holding.id] = forecast
                } else {
                    nextReasons[holding.id] = L10n.t("At least 20 completed daily returns are required.")
                }
            }
            try Task.checkCancellation()
            forecasts = next
            reasons = nextReasons
            message = nil
        } catch is CancellationError {
            return
        } catch let error as TossInvestAPI.Failure {
            forecasts = [:]
            if case .http(429) = error {
                message = L10n.t("Toss Securities rate limit reached. Retrying soon.")
            } else {
                message = L10n.t("Could not load account holdings. Check API keys, account access, and allowed IP.")
            }
        } catch {
            forecasts = [:]
            message = L10n.t("Could not load account holdings. Check API keys, account access, and allowed IP.")
        }
    }

    private func clearHoldings() {
        holdings = []
        forecasts = [:]
        reasons = [:]
        holdingsAt = nil
        completedCloses = [:]
        historySession = [:]
        historyAttempt = [:]
    }
}
