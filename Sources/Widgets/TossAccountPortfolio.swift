import Combine
import Foundation

/// Private account data is decoded separately from public forecast inputs. Never Codable/exported.
struct TossAccountDecimal: Decodable, Equatable {
    let value: Decimal

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard text.count <= 30,
              text.range(of: #"\A-?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, NSDecimalNumber(decimal: number).doubleValue.isFinite else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid account amount")
        }
        value = number
    }
}

struct TossAccountAmounts: Decodable {
    let krw: TossAccountDecimal
    let usd: TossAccountDecimal?
}

struct TossAccountMarketValue: Decodable {
    let amount: TossAccountAmounts
    let amountAfterCost: TossAccountAmounts
}

struct TossAccountProfitLoss: Decodable {
    let amount: TossAccountAmounts
    let amountAfterCost: TossAccountAmounts
    let rate: TossAccountDecimal
    let rateAfterCost: TossAccountDecimal
}

struct TossAccountDailyProfitLoss: Decodable {
    let amount: TossAccountAmounts
    let rate: TossAccountDecimal
}

struct TossAccountPosition: Decodable, Identifiable {
    struct MarketValue: Decodable {
        let purchaseAmount: TossAccountDecimal
        let amount: TossAccountDecimal
        let amountAfterCost: TossAccountDecimal
    }
    struct ProfitLoss: Decodable {
        let amount: TossAccountDecimal
        let amountAfterCost: TossAccountDecimal
        let rate: TossAccountDecimal
        let rateAfterCost: TossAccountDecimal
    }
    struct DailyProfitLoss: Decodable {
        let amount: TossAccountDecimal
        let rate: TossAccountDecimal
    }
    struct Cost: Decodable {
        let commission: TossAccountDecimal
        let tax: TossAccountDecimal?
    }
    let symbol: String
    let name: String
    let marketCountry: String
    let currency: String
    let quantity: TossAccountDecimal
    let lastPrice: TossAccountDecimal
    let averagePurchasePrice: TossAccountDecimal
    let marketValue: MarketValue
    let profitLoss: ProfitLoss
    let dailyProfitLoss: DailyProfitLoss
    let cost: Cost
    var id: String { "\(marketCountry):\(symbol)" }
}

struct TossAccountPortfolio: Decodable {
    let totalPurchaseAmount: TossAccountAmounts
    let marketValue: TossAccountMarketValue
    let profitLoss: TossAccountProfitLoss
    let dailyProfitLoss: TossAccountDailyProfitLoss
    let items: [TossAccountPosition]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw TossInvestAPI.Failure.invalidResponse }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["error"] == nil || envelope["error"] is NSNull else { throw TossInvestAPI.Failure.invalidResponse }
        let portfolio = try JSONDecoder().decode(TossResult<Self>.self, from: data).result
        guard Set(portfolio.items.map(\.id)).count == portfolio.items.count,
              portfolio.totalPurchaseAmount.krw.value >= 0,
              portfolio.totalPurchaseAmount.usd.map({ $0.value >= 0 }) ?? true,
              portfolio.marketValue.amount.krw.value >= 0,
              portfolio.marketValue.amount.usd.map({ $0.value >= 0 }) ?? true,
              portfolio.items.allSatisfy({ item in
                  guard item.marketCountry.range(of: #"\A[A-Z]{1,20}\z"#, options: .regularExpression) != nil,
                        item.currency.range(of: #"\A[A-Z]{1,20}\z"#, options: .regularExpression) != nil,
                        item.symbol.range(of: #"\A[A-Z0-9.\-]{1,20}\z"#, options: .regularExpression) != nil else { return false }
                  if ["KR", "US"].contains(item.marketCountry) {
                      guard WatchedStock.parse(item.id) != nil else { return false }
                      if ["KRW", "USD"].contains(item.currency),
                         item.currency != (item.marketCountry == "KR" ? "KRW" : "USD") { return false }
                  }
                  return item.name.count <= 200 && !item.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                      && item.quantity.value >= 0 && item.lastPrice.value >= 0
                      && item.averagePurchasePrice.value >= 0 && item.marketValue.purchaseAmount.value >= 0
                      && item.marketValue.amount.value >= 0 && item.cost.commission.value >= 0
                      && (item.cost.tax.map({ $0.value >= 0 }) ?? true)
              }) else { throw TossInvestAPI.Failure.invalidResponse }
        return portfolio
    }
}

/// One memory-only snapshot shared by Settings and the explicitly enabled account cell.
@MainActor
final class TossAccountStore: ObservableObject {
    static let shared = TossAccountStore()
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var accounts: [TossAccount] = []
    @Published private(set) var selectedAccount = 0
    @Published private(set) var portfolio: TossAccountPortfolio?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var notchAccount = 0
    private var notchRevision: Int?
    private var notchSource: StockQuoteSource?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let refreshInterval: Duration
    private let clock: () -> Date
    private var requestTask: Task<Void, Never>?
    private let session: URLSession
    private let credentials: () -> (clientID: String, clientSecret: String)

    init(session: URLSession? = nil,
         credentials: @escaping () -> (clientID: String, clientSecret: String) = TossCredentials.load,
         refreshInterval: Duration = .seconds(60), clock: @escaping () -> Date = Date.init) {
        self.refreshInterval = refreshInterval
        self.clock = clock
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
        self.credentials = credentials
    }

    func start(preferences: Preferences) {
        guard cancellables.isEmpty else { return }
        preferences.$accountNotchEnabled.combineLatest(preferences.$accountNotchSeq,
            preferences.$stockQuoteSource, preferences.$stockSettingsRevision)
            .sink { [weak self] enabled, account, source, revision in
                self?.configureNotch(enabled: enabled, account: account, source: source, revision: revision)
            }.store(in: &cancellables)
    }

    // Called synchronously by preferences: disabling invalidates queued and in-flight private reads.
    func configureNotch(enabled: Bool, account: Int, source: StockQuoteSource, revision: Int) {
        let next = enabled && source == .toss && (1...9_007_199_254_740_991).contains(account) ? account : 0
        guard next != notchAccount || revision != notchRevision || source != notchSource else { return }
        let sameEpoch = revision == notchRevision && source == notchSource
        let knownAccounts = sameEpoch ? accounts : []
        let reuse = sameEpoch
            && selectedAccount == next && portfolio != nil && next > 0
        pollTask?.cancel()
        pollTask = nil
        if !reuse {
            hide()
            if next > 0 { accounts = knownAccounts }
        }
        notchAccount = next
        notchRevision = revision
        notchSource = source
        publish()
        guard next > 0 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.updatedAt.map({
                    let age = self.clock().timeIntervalSince($0)
                    return age < 0 || age >= 60
                }) ?? true {
                    await self.refreshNotch()
                }
                do { try await Task.sleep(for: self.refreshInterval) } catch { return }
            }
        }
    }

    func hideViewer() { if notchAccount == 0 { hide() } }

    func refreshNotch() async {
        let account = notchAccount
        guard account > 0, !loading else { return }
        if !accounts.contains(where: { $0.accountSeq == account }) {
            await startLoadingAccounts().value
        }
        guard !Task.isCancelled, notchAccount == account else { return }
        guard accounts.contains(where: { $0.accountSeq == account }) else {
            if message == nil { message = L10n.t("The selected account is unavailable. Load accounts again.") }
            publish()
            return
        }
        await startSelecting(account).value
    }

    private func publish() {
        let next = notchAccount > 0 ? [Self.snapshot(portfolio: selectedAccount == notchAccount ? portfolio : nil,
                                                   updatedAt: updatedAt, message: message)] : []
        if snapshots != next { snapshots = next }
    }

    static func snapshot(portfolio: TossAccountPortfolio? = nil, updatedAt: Date? = nil,
                         message: String? = nil, locale: Locale = L10n.locale) -> ProviderSnapshot {
        guard let portfolio else {
            return ProviderSnapshot(id: "widget-account", displayName: L10n.t("Stock assets"), glyph: .stock,
                fidelity: .official, status: .unsupported(message ?? L10n.t("Loading account information…")),
                windows: [], kind: .stocks, ringLabel: L10n.t("Account"), plan: "Toss Securities")
        }
        let rate = NSDecimalNumber(decimal: portfolio.dailyProfitLoss.rate.value).doubleValue
        let percent = (rate > 0 ? "+" : "") + TossAccountDisplay.percent(portfolio.dailyProfitLoss.rate, locale: locale)
        var rows = [LimitWindow(id: "daily", label: L10n.t("Daily return (KRW basis)"),
            usedFraction: min(1, abs(rate) / 0.30), usedText: percent, detail: percent,
            bandOverride: rate > 0 ? .ample : rate < 0 ? .critical : nil, prefersUsedText: true)]
        rows += [
            LimitWindow(id: "value-krw", label: "KRW · \(L10n.t("Market value"))",
                        detail: TossAccountDisplay.money(portfolio.marketValue.amount.krw, currency: "KRW")),
            LimitWindow(id: "value-usd", label: "USD · \(L10n.t("Market value"))",
                        detail: TossAccountDisplay.money(portfolio.marketValue.amount.usd, currency: "USD")),
            LimitWindow(id: "daily-krw", label: "KRW · \(L10n.t("Daily profit/loss"))",
                        detail: TossAccountDisplay.money(portfolio.dailyProfitLoss.amount.krw, currency: "KRW")),
            LimitWindow(id: "daily-usd", label: "USD · \(L10n.t("Daily profit/loss"))",
                        detail: TossAccountDisplay.money(portfolio.dailyProfitLoss.amount.usd, currency: "USD")),
            LimitWindow(id: "updated", label: L10n.t("Last refreshed"),
                        detail: updatedAt?.formatted(date: .numeric, time: .standard) ?? "—"),
            LimitWindow(id: "scope", label: L10n.t("Stock assets"), detail: L10n.t("Cash, bonds and options are not included."))
        ]
        return ProviderSnapshot(id: "widget-account", displayName: L10n.t("Stock assets"), glyph: .stock,
            fidelity: .official, status: .ok, windows: rows, headlineID: "daily", kind: .stocks,
            ringLabel: L10n.t("Account"), plan: "Toss Securities")
    }

    func hide() {
        pollTask?.cancel()
        pollTask = nil
        notchAccount = 0
        requestTask?.cancel()
        requestTask = nil
        generation = UUID()
        accounts = []
        selectedAccount = 0
        portfolio = nil
        updatedAt = nil
        loading = false
        message = nil
        publish()
    }

    @discardableResult
    func startLoadingAccounts() -> Task<Void, Never> {
        requestTask?.cancel()
        let expected = generation
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            await self.loadAccounts()
        }
        requestTask = task
        return task
    }

    @discardableResult
    func startSelecting(_ account: Int) -> Task<Void, Never> {
        requestTask?.cancel()
        let expected = generation
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            await self.select(account)
        }
        requestTask = task
        return task
    }

    private func token() async throws -> TossInvestAPI.AccessToken {
        let saved = credentials()
        guard !saved.clientID.isEmpty, !saved.clientSecret.isEmpty else { throw TossInvestAPI.Failure.invalidResponse }
        return try await TossInvestAPI.accessToken(clientID: saved.clientID, clientSecret: saved.clientSecret, session: session)
    }

    private func loadAccounts() async {
        guard !loading, !Task.isCancelled else { return }
        generation = UUID()
        accounts = []
        selectedAccount = 0
        portfolio = nil
        updatedAt = nil
        message = nil
        let generation = self.generation
        loading = true
        publish()
        defer { if generation == self.generation { loading = false; publish() } }
        do {
            let token = try await token()
            guard generation == self.generation, !Task.isCancelled else { return }
            let result = try await TossInvestAPI.accounts(token: token.value, session: session)
            guard generation == self.generation, !Task.isCancelled else { return }
            guard Set(result.map(\.accountSeq)).count == result.count,
                  result.allSatisfy({ $0.accountSeq > 0 && $0.accountSeq <= 9_007_199_254_740_991
                      && !$0.accountNo.isEmpty && $0.accountNo.count <= 100
                      && !$0.accountNo.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw TossInvestAPI.Failure.invalidResponse
            }
            accounts = result.filter { $0.accountType == "BROKERAGE" }
            if accounts.isEmpty { message = L10n.t("No supported Toss Securities account was found.") }
        } catch {
            if generation == self.generation, !Task.isCancelled {
                message = L10n.t("Could not load account information. Check your saved keys, allowed IP and account access.")
            }
        }
    }

    private func select(_ account: Int) async {
        guard !Task.isCancelled else { return }
        generation = UUID()
        let generation = self.generation
        let nextAccount = accounts.contains(where: { $0.accountSeq == account }) ? account : 0
        if selectedAccount != nextAccount { portfolio = nil; updatedAt = nil }
        selectedAccount = nextAccount
        message = nil
        loading = false
        publish()
        guard selectedAccount > 0 else { return }
        loading = true
        publish()
        defer { if generation == self.generation { loading = false; publish() } }
        do {
            let token = try await token()
            guard generation == self.generation, !Task.isCancelled else { return }
            let result = try await TossInvestAPI.accountPortfolio(token: token.value, accountSeq: account, session: session)
            guard generation == self.generation, !Task.isCancelled else { return }
            portfolio = result
            updatedAt = clock()
        } catch {
            if generation == self.generation, !Task.isCancelled {
                portfolio = nil
                updatedAt = nil
                message = L10n.t("Could not load account information. Check your saved keys, allowed IP and account access.")
            }
        }
    }
}
