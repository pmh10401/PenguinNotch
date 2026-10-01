import SwiftUI

struct TossAccountView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var account: TossAccountStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                L10n.t(
                    "Read-only stock assets. Private values stay in memory while this screen or the account notch is active."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t("Load accounts")) { account.startLoadingAccounts() }
                    .disabled(account.loading)
                Button(L10n.t("Hide account information")) {
                    preferences.accountNotchEnabled = false
                    account.hide()
                }
                .disabled(account.accounts.isEmpty && !account.loading)
            }
            if !account.accounts.isEmpty {
                Picker(
                    L10n.t("Toss Securities account"),
                    selection: Binding(
                        get: { account.selectedAccount }, set: { selectAccount($0) })
                ) {
                    Text(L10n.t("Select an account")).tag(0)
                    ForEach(account.accounts) { Text($0.maskedNumber).tag($0.accountSeq) }
                }
                Button(L10n.t("Refresh account information")) {
                    account.startSelecting(account.selectedAccount)
                }
                .disabled(account.selectedAccount == 0 || account.loading)
            }
            Toggle(
                L10n.t("Show account in notch"),
                isOn: Binding(
                    get: { preferences.accountNotchEnabled },
                    set: { enabled in
                        if enabled { preferences.accountNotchSeq = account.selectedAccount }
                        preferences.accountNotchEnabled = enabled
                        if enabled { preferences.hiddenNotchItems.remove("widget-account") }
                    })
            )
            .disabled(
                !preferences.accountNotchEnabled
                    && (account.selectedAccount == 0 || account.portfolio == nil || account.loading))
            Text(
                L10n.t(
                    "The account notch refreshes every 60 seconds and shows the API daily return. Only the account selector and display choice are saved."
                )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(
                L10n.t("Include account holdings in estimates"),
                isOn: Binding(
                    get: { preferences.tossAccountSeq > 0 }, set: includeHoldings)
            )
            .disabled(
                preferences.tossAccountSeq == 0
                    && (account.selectedAccount == 0 || account.portfolio == nil || account.loading))
            Text(
                L10n.t(
                    "The enabled account features follow your selection. Watchlist estimates work without an account.")
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if preferences.tossAccountSeq > 0 && preferences.tossAccountSeq != account.selectedAccount {
                Text(L10n.t("Estimates use a saved account. Select an account to change it, or turn off holdings."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if account.loading { ProgressView(L10n.t("Loading account information…")) }
            if let message = account.message {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            }
            if let portfolio = account.portfolio {
                TossAccountSummaryView(portfolio: portfolio)
                if let date = account.updatedAt {
                    LabeledContent(L10n.t("Last refreshed")) { Text(date, style: .time) }
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(String(format: L10n.t("Holdings (%d)"), portfolio.items.count)) {
                    if portfolio.items.isEmpty {
                        Text(L10n.t("This account has no supported stock holdings."))
                    }
                    ForEach(portfolio.items) { position in
                        DisclosureGroup {
                            TossAccountPositionView(position: position)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(position.name.isEmpty ? position.symbol : position.name).font(.headline)
                                Text("\(position.marketCountry) · \(position.symbol) · \(position.currency)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(
                                    "\(L10n.t("Profit/loss")): \(TossAccountDisplay.money(position.profitLoss.amount, currency: position.currency)) · \(TossAccountDisplay.percent(position.profitLoss.rate))"
                                )
                                .foregroundStyle(TossAccountDisplay.color(position.profitLoss.amount))
                            }
                        }
                    }
                }
            }
            Text(
                L10n.t(
                    "KRW and USD are shown separately. Overall returns are the API's KRW-converted ratios. Cash, bonds and options are not included."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { account.hideViewer() }
    }

    @discardableResult
    func selectAccount(_ value: Int) -> Task<Void, Never>? {
        guard value == 0 || account.accounts.contains(where: { $0.accountSeq == value }) else { return nil }
        if preferences.tossAccountSeq > 0 { preferences.tossAccountSeq = value }
        if preferences.accountNotchEnabled {
            if value == 0 { preferences.accountNotchEnabled = false }
            preferences.accountNotchSeq = value
        } else {
            return account.startSelecting(value)
        }
        return nil
    }

    func includeHoldings(_ enabled: Bool) {
        if enabled {
            guard account.selectedAccount > 0, account.portfolio != nil, !account.loading else { return }
            preferences.tossAccountSeq = account.selectedAccount
        } else {
            preferences.tossAccountSeq = 0
        }
    }
}

struct TossAccountSummaryView: View {
    let portfolio: TossAccountPortfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Stock asset summary")).font(.headline)
            amounts("Market value", portfolio.marketValue.amount)
            amounts("Daily profit/loss", portfolio.dailyProfitLoss.amount)
            LabeledContent(L10n.t("Daily return (KRW basis)")) {
                Text(TossAccountDisplay.percent(portfolio.dailyProfitLoss.rate))
                    .foregroundStyle(TossAccountDisplay.color(portfolio.dailyProfitLoss.rate))
            }
            DisclosureGroup(L10n.t("Return details")) {
                amounts("Investment principal", portfolio.totalPurchaseAmount)
                amounts("Profit/loss", portfolio.profitLoss.amount)
                LabeledContent(L10n.t("Overall return (KRW basis)")) {
                    Text(TossAccountDisplay.percent(portfolio.profitLoss.rate))
                        .foregroundStyle(TossAccountDisplay.color(portfolio.profitLoss.rate))
                }
                DisclosureGroup(L10n.t("After taxes and fees")) {
                    amounts("Market value", portfolio.marketValue.amountAfterCost)
                    amounts("Profit/loss", portfolio.profitLoss.amountAfterCost)
                    LabeledContent(L10n.t("Overall return (KRW basis)")) {
                        Text(TossAccountDisplay.percent(portfolio.profitLoss.rateAfterCost))
                    }
                }
            }
        }
        .monospacedDigit()
    }

    private func amounts(_ label: String.LocalizationValue, _ amounts: TossAccountAmounts) -> some View {
        LabeledContent(L10n.t(label)) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("KRW · \(TossAccountDisplay.money(amounts.krw, currency: "KRW"))")
                Text("USD · \(TossAccountDisplay.money(amounts.usd, currency: "USD"))")
            }
        }
    }
}

struct TossAccountPositionView: View {
    let position: TossAccountPosition

    var body: some View {
        VStack(spacing: 6) {
            LabeledContent(L10n.t("Quantity"), value: TossAccountDisplay.quantity(position.quantity))
            money("Average purchase price", position.averagePurchasePrice)
            money("Current price", position.lastPrice)
            money("Investment principal", position.marketValue.purchaseAmount)
            money("Market value", position.marketValue.amount)
            money("Profit/loss", position.profitLoss.amount)
            LabeledContent(L10n.t("Return"), value: TossAccountDisplay.percent(position.profitLoss.rate))
            money("Daily profit/loss", position.dailyProfitLoss.amount)
            LabeledContent(L10n.t("Daily return"), value: TossAccountDisplay.percent(position.dailyProfitLoss.rate))
            DisclosureGroup(L10n.t("After taxes and fees")) {
                money("Market value", position.marketValue.amountAfterCost)
                money("Profit/loss", position.profitLoss.amountAfterCost)
                LabeledContent(L10n.t("Return"), value: TossAccountDisplay.percent(position.profitLoss.rateAfterCost))
                money("Commission", position.cost.commission)
                money("Tax", position.cost.tax)
            }
        }
        .monospacedDigit()
        .padding(.vertical, 6)
    }

    private func money(_ label: String.LocalizationValue, _ value: TossAccountDecimal?) -> some View {
        LabeledContent(L10n.t(label), value: TossAccountDisplay.money(value, currency: position.currency))
    }
}

enum TossAccountDisplay {
    static func money(_ value: TossAccountDecimal?, currency: String) -> String {
        guard let value else { return "—" }
        if ["KRW", "USD"].contains(currency) {
            return StockQuoteCodec.format(price: value.value, currency: currency, locale: .current)
        }
        return "\(currency) \(quantity(value))"
    }

    static func quantity(_ value: TossAccountDecimal, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 28
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
    }

    static func percent(_ value: TossAccountDecimal, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
    }

    static func color(_ value: TossAccountDecimal) -> Color {
        value.value > 0 ? .green : value.value < 0 ? .red : .secondary
    }
}
