import SwiftUI

enum StockSettingsPage: CaseIterable, Hashable {
    case watchlist, account, analysis, history

    var title: String {
        switch self {
        case .watchlist: L10n.t("Watchlist")
        case .account: L10n.t("My account")
        case .analysis: L10n.t("Analysis")
        case .history: L10n.t("History")
        }
    }
}

struct StockSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject private var portfolio: StockForecastStore
    @ObservedObject private var account: TossAccountStore
    @ObservedObject private var backtests: StockBacktestStore
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var finnhubKey = ""
    @State private var symbol = ""
    @State private var message: String?
    @State private var apiMessage: String?
    @State private var showsFinnhubKeys = false
    @State private var showsTossKeys = false
    @State private var showsForecastHistory = false
    @State private var forecastSaveMessage: String?
    @State private var page: StockSettingsPage
    @State private var showsConnection = false
    @State private var showsCodexAnalysis = false

    init(
        preferences: Preferences, portfolio: StockForecastStore = .shared,
        account: TossAccountStore = .shared, page: StockSettingsPage = .watchlist
    ) {
        self.preferences = preferences
        self.portfolio = portfolio
        self.account = account
        self.backtests = StockBacktestStore.shared(preferences: preferences)
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.t("Stock settings"), selection: $page) {
                ForEach(StockSettingsPage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20).padding(.vertical, 12)
            Form {
                switch page {
                case .watchlist:
                    Section {
                        Toggle(L10n.t("Show stocks in notch"), isOn: $preferences.showsStocks)
                        Text(
                            L10n.t(
                                "Keep a watchlist of up to 30 Korean or US stocks. Turning this off keeps your list and keys."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    watchlistSection
                    Section {
                        DisclosureGroup(L10n.t("Display options")) {
                            Stepper(value: $preferences.stockDisplayInterval, in: 1...10) {
                                Text(
                                    String(format: L10n.t("Switch every %d seconds"), preferences.stockDisplayInterval))
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(isExpanded: $showsConnection) {
                            connectionContent
                        } label: {
                            LabeledContent(L10n.t("Connection"), value: preferences.stockQuoteSource.title)
                        }
                        if let apiMessage { Text(apiMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                case .account:
                    Section(L10n.t("My Toss account")) {
                        if preferences.stockQuoteSource == .toss {
                            TossAccountView(preferences: preferences, account: account)
                        } else {
                            Text(L10n.t("Accounts require Toss Securities."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.t("Manage connection")) {
                                page = .watchlist
                                showsConnection = true
                            }
                        }
                    }
                case .analysis:
                    if preferences.stockQuoteSource == .toss {
                        chartSection
                        technicalSection
                        forecastSection
                        Section {
                            DisclosureGroup(L10n.t("Codex analysis"), isExpanded: $showsCodexAnalysis) {
                                if showsCodexAnalysis { codexContent }
                            }
                        }
                    } else {
                        Section {
                            Text(
                                L10n.t(
                                    "US quotes refresh about every minute. Korean stocks and candlestick charts are not supported with Finnhub."
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.t("Manage connection")) {
                                page = .watchlist
                                showsConnection = true
                            }
                        }
                    }
                case .history:
                    Section(L10n.t("Forecast history and evaluation")) {
                        Button(L10n.t("Forecast history and evaluation")) { showsForecastHistory = true }
                        Text(
                            L10n.t(
                                "Compare saved predictions with the matching Toss daily close after the next local calendar date. Automatic and manual records are scored separately."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .id(page)
        }
        .sheet(isPresented: $showsForecastHistory) { StockForecastHistoryView(journal: portfolio.journal, analyses: .shared, backtests: backtests) }
        .onAppear { portfolio.setSettingsVisible(true) }
        .onDisappear {
            portfolio.setSettingsVisible(false)
            clearKeyInputs()
        }
        .onChange(of: page) { _, _ in clearKeyInputs() }
        .onChange(of: preferences.stockQuoteSource) { _, _ in
            apiMessage = nil
            message = nil
            clearKeyInputs()
        }
    }

    private func clearKeyInputs() {
        showsFinnhubKeys = false
        showsTossKeys = false
        clientID = ""
        clientSecret = ""
        finnhubKey = ""
    }

    @ViewBuilder
    private var connectionContent: some View {
        Picker(L10n.t("Quote provider"), selection: Binding(get: { preferences.stockQuoteSource }, set: { backtests.cancel(); preferences.stockQuoteSource = $0 })) {
            ForEach(StockQuoteSource.allCases) { source in Text(source.title).tag(source) }
        }
        Text(L10n.t("Only the selected provider is used. Switching keeps your watchlist and saved keys."))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if preferences.stockQuoteSource == .finnhub {
            Text(
                L10n.t(
                    "US quotes refresh about every minute. Korean stocks and candlestick charts are not supported with Finnhub."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.t("Finnhub API key"), isExpanded: $showsFinnhubKeys) {
                if showsFinnhubKeys {
                    SecureField(L10n.t("Finnhub API key"), text: $finnhubKey)
                    HStack {
                        Button(L10n.t("Save Finnhub key")) {
                            backtests.cancel()
                            if FinnhubCredentials.save(finnhubKey) {
                                finnhubKey = ""
                                preferences.stockSettingsRevision += 1
                                apiMessage = L10n.t("Finnhub key saved")
                            } else {
                                apiMessage = L10n.t("Could not save Finnhub key")
                            }
                        }
                        .disabled(finnhubKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(L10n.t("Remove Finnhub key")) {
                            backtests.cancel()
                            FinnhubCredentials.clear()
                            finnhubKey = ""
                            preferences.stockSettingsRevision += 1
                            apiMessage = nil
                        }
                    }
                    Link(L10n.t("Get a free Finnhub key"), destination: URL(string: "https://finnhub.io/register")!)
                        .font(.caption)
                }
            }
        } else {
            DisclosureGroup(L10n.t("Toss Securities API keys"), isExpanded: $showsTossKeys) {
                if showsTossKeys {
                    Text(
                        L10n.t(
                            "For Korean and US quotes and charts, register this Mac’s public IP in Toss Securities WTS → Settings → Open API → Allowed IPs. Keys stay in the Keychain."
                        )
                    )
                    .onAppear { if clientID.isEmpty { clientID = TossCredentials.load().clientID } }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    TextField(L10n.t("Client ID"), text: $clientID)
                    SecureField(L10n.t("Client secret"), text: $clientSecret)
                    HStack {
                        Button(L10n.t("Save API keys")) {
                            backtests.cancel()
                            TossCredentials.save(clientID: clientID, clientSecret: clientSecret)
                            clientSecret = ""
                            preferences.stockSettingsRevision += 1
                            apiMessage = L10n.t("API keys saved")
                        }
                        .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(L10n.t("Remove API keys")) {
                            backtests.cancel()
                            TossCredentials.clear()
                            clientID = ""
                            clientSecret = ""
                            preferences.stockSettingsRevision += 1
                            apiMessage = nil
                        }
                    }
                }
            }
        }

    }

    @ViewBuilder
    private var watchlistSection: some View {
        Section(L10n.t("Watchlist")) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.t("Add symbol"), systemImage: "plus.circle.fill")
                    .font(.headline)
                HStack {
                    let prompt = L10n.t(
                        preferences.stockQuoteSource == .toss
                            ? "Company name or symbol · 삼성전자, 005930, AAPL" : "US ticker · AAPL, SOXL")
                    TextField(prompt, text: $symbol, prompt: Text(prompt))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit(add)
                    Button(L10n.t("Add symbol"), action: add)
                        .buttonStyle(SettingsButtonStyle(kind: .prominent))
                        .disabled(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if preferences.stockQuoteSource == .toss, WatchedStock.parse(symbol) == nil {
                    ForEach(KoreanStockDirectory.shared.search(symbol)) { company in
                        Button("\(company.name) · \(company.code) (\(company.market))") {
                            add(company.code)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))

            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if preferences.stockSymbols.isEmpty {
                Text(L10n.t("Your watchlist is empty. Add a company name, Korean code or US ticker above."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let stocks = preferences.orderedStocks
            ForEach(stocks) { stock in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                        .draggable(stock.id)
                        .help(L10n.t("Drag to reorder"))
                    NotchItemAppearanceRow(
                        preferences: preferences,
                        snapshot: StockBoard.snapshot(
                            stock: stock, quote: nil, previousClose: nil,
                            name: nil, link: .idle, source: preferences.stockQuoteSource),
                        subtitle: preferences.stockQuoteSource.supports(stock)
                            ? "\(stock.market.rawValue.uppercased()) · \(stock.symbol)"
                            : L10n.t("Not supported by Finnhub"))
                    Button {
                        step(stock.id, by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(stocks.first?.id == stock.id)
                    .accessibilityLabel(L10n.t("Move \(stock.symbol) up"))
                    Button {
                        step(stock.id, by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(stocks.last?.id == stock.id)
                    .accessibilityLabel(L10n.t("Move \(stock.symbol) down"))
                    Button {
                        preferences.removeStockSymbol(stock.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("Remove \(stock.symbol)"))
                    .accessibilityLabel(L10n.t("Remove \(stock.symbol)"))
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    guard ids.count == 1, let moved = ids.first else { return false }
                    return preferences.moveStockSymbol(moved, onto: stock.id)
                }
            }
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        Section(L10n.t("Hover chart")) {
            HStack {
                Text(L10n.t("Stock candles to show"))
                Spacer()
                TextField(L10n.t("Candles"), value: $preferences.stockChartCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                Stepper(L10n.t("Candles"), value: $preferences.stockChartCount, in: 1...20)
                    .labelsHidden()
            }
            Picker(L10n.t("Default chart interval"), selection: $preferences.stockChartInterval) {
                ForEach(StockChartInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            Text(L10n.t("1–20 candles · 1m every minute, 10m every 10 minutes, 1d daily"))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.t("Moving averages")) {
                ForEach(StockQuoteCodec.movingAveragePeriods, id: \.self) { period in
                    Toggle(
                        "SMA \(period)",
                        isOn: Binding(
                            get: { preferences.stockMovingAveragePeriods.contains(period) },
                            set: { enabled in
                                preferences.stockMovingAveragePeriods =
                                    enabled
                                    ? preferences.stockMovingAveragePeriods + [period]
                                    : preferences.stockMovingAveragePeriods.filter { $0 != period }
                            }))
                }
                Text(
                    L10n.t(
                        "Daily charts use trading days; minute charts use bars. Averages include history before the 20 visible candles. The newest chart bar may still change. Line visibility does not change the SMA 5/20 signal rule."
                    )
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        Section(L10n.t("Technical analysis")) {
            Toggle(L10n.t("Show buy/sell review signals"), isOn: $preferences.showsStockTimingSignals)
            DisclosureGroup(L10n.t("How analysis works")) {
                Text(
                    L10n.t(
                        "Analyze the latest 20 completed bars, including earlier trading days, for every watchlist stock. Minute charts also include extended-hours bars; daily analysis excludes today's bar. No account access is needed."
                    )
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(
                    L10n.t(
                        "Volume ≥1.5× the previous 10 bars, SMA 5/20 trend, and a 10-bar breakout must agree. Experimental rules; no orders are placed."
                    )
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var forecastSection: some View {
        Section(L10n.t("Stock close estimates")) {
            Toggle(
                L10n.t("Show estimates for watchlist stocks"),
                isOn: $preferences.portfolioForecastEnabled)
            if preferences.portfolioForecastEnabled {
                Text(
                    L10n.t(
                        "Hover a stock in the notch. The selected 1m, 10m or 1d bars set volatility for today's regular close. Daily forecast history remains separate."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(
                        L10n.t(
                            preferences.tossAccountSeq > 0
                                ? "Watchlist and account holdings" : "Watchlist only (no account access)")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("Manage accounts")) { page = .account }
                }
                if let message = portfolio.accountMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if portfolio.loading { ProgressView(L10n.t("Loading estimates…")) }
                if let message = portfolio.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.t("Current estimates")) {
                    ForEach(portfolio.targets(for: preferences)) { target in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(target.name)
                                .font(.headline)
                            Text("\(target.stock.market.rawValue.uppercased()) · \(target.stock.symbol)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let estimate = portfolio.forecasts[target.id] {
                                let up = Int((estimate.riseProbability * 100).rounded())
                                HStack(spacing: 16) {
                                    Text("\(L10n.t("Rise")) ≈\(up)%")
                                        .foregroundStyle(.green)
                                    Text("\(L10n.t("Fall")) ≈\(100 - up)%")
                                        .foregroundStyle(.red)
                                }
                                Text(
                                    "\(L10n.t("Estimated close")): \(StockQuoteCodec.format(price: estimate.expectedClose, currency: target.currency, locale: .current))"
                                )
                                .font(.subheadline)
                                Text(
                                    "\(L10n.t("Model 80% range")): \(StockQuoteCodec.format(price: estimate.lowerClose, currency: target.currency, locale: .current)) – \(StockQuoteCodec.format(price: estimate.upperClose, currency: target.currency, locale: .current))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if let record = portfolio.candidates.first(where: { $0.stockID == target.id }) {
                                    DisclosureGroup(L10n.t("Prediction evidence")) {
                                        ForecastEvidenceView(record: record).padding(.vertical, 6)
                                    }
                                }
                            } else if let reason = portfolio.reasons[target.id] {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
                DisclosureGroup(L10n.t("How estimates work")) {
                    Text(
                        L10n.t(
                            "Experimental, uncalibrated model: 20–60 completed daily returns set volatility. Today's fresh price is the expected close; rise/fall odds assume zero drift until the regular close. Not an investment signal."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(L10n.t("Recording options")) {
                    Toggle(
                        L10n.t("Automatically record and evaluate forecasts"), isOn: $preferences.recordsStockForecasts)
                    Text(
                        L10n.t(
                            "While this app is running, save one fresh prediction per stock 55–60 minutes before the regular close, even with Settings closed. Symbols, prices, dates, and model results are stored only on this Mac. Missed predictions are not backfilled."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.t("Save current predictions")) {
                        let saved = portfolio.saveCurrent()
                        forecastSaveMessage =
                            portfolio.journal.errorMessage
                            ?? (saved > 0
                                ? String(format: L10n.t("Saved %d predictions."), saved)
                                : L10n.t(
                                    "Already saved today, or waiting for a fresh quote. Existing predictions are never replaced."
                                ))
                    }
                    .disabled(portfolio.candidates.isEmpty)
                    if let forecastSaveMessage {
                        Text(forecastSaveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var codexContent: some View {
        Text(
            L10n.t(
                "Manual analysis sends this symbol, quote and completed daily closes to Codex. It uses your signed-in Codex allowance."
            )
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
            L10n.t(
                "Install Codex CLI and sign in with ChatGPT first. One prediction per stock and trading day is saved separately from GBM; account balances and holdings are not sent."
            )
        )
        .font(.caption).foregroundStyle(.secondary)
        if preferences.stockQuoteSource == .toss && preferences.portfolioForecastEnabled {
            ForEach(preferences.orderedStocks) { stock in
                DisclosureGroup(stock.symbol) {
                    StockCodexAnalysisView(
                        stockID: stock.id,
                        input: portfolio.candidates.first { $0.stockID == stock.id }
                    )
                    .padding(.vertical, 6)
                }
            }
        } else {
            Text(L10n.t("Enable Toss watchlist estimates to analyze with Codex."))
                .font(.caption).foregroundStyle(.secondary)
        }

    }

    private func add() {
        add(symbol)
    }

    private func step(_ id: String, by offset: Int) {
        let ids = preferences.orderedStocks.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        preferences.moveStockSymbol(id, onto: ids[index + offset])
    }

    private func add(_ input: String) {
        guard let stock = KoreanStockDirectory.shared.resolve(input) else {
            message = L10n.t("Company not found. Select a match or enter a Korean stock code or US ticker.")
            return
        }
        guard preferences.stockQuoteSource.supports(stock) else {
            message = L10n.t("Finnhub supports US quotes only. Select Toss Securities for Korean stocks.")
            return
        }
        guard preferences.addStockSymbol(stock.id) else {
            message = L10n.t("The stock list holds 30 symbols.")
            return
        }
        symbol = ""
        message = nil
    }
}
