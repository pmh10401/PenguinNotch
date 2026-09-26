import SwiftUI

struct StockSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject private var portfolio = StockForecastStore.shared
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

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("Show stocks in notch"), isOn: $preferences.showsStocks)
                Text(L10n.t("Keep a watchlist of up to 30 Korean or US stocks. Turning this off keeps your list and keys."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.t("Quote provider")) {
                Picker(L10n.t("Quote provider"), selection: $preferences.stockQuoteSource) {
                    ForEach(StockQuoteSource.allCases) { source in Text(source.title).tag(source) }
                }
                Text(L10n.t("Only the selected provider is used. Switching keeps your watchlist and saved keys."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if preferences.stockQuoteSource == .finnhub {
                    Text(L10n.t("US quotes refresh about every minute. Korean stocks and candlestick charts are not supported with Finnhub."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.t("Finnhub API key"), isExpanded: $showsFinnhubKeys) {
                        if showsFinnhubKeys {
                            SecureField(L10n.t("Finnhub API key"), text: $finnhubKey)
                            HStack {
                                Button(L10n.t("Save Finnhub key")) {
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
                            Text(L10n.t("For Korean and US quotes and charts, register this Mac’s public IP in Toss Securities WTS → Settings → Open API → Allowed IPs. Keys stay in the Keychain."))
                                .onAppear { if clientID.isEmpty { clientID = TossCredentials.load().clientID } }
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextField(L10n.t("Client ID"), text: $clientID)
                            SecureField(L10n.t("Client secret"), text: $clientSecret)
                            HStack {
                                Button(L10n.t("Save API keys")) {
                                    TossCredentials.save(clientID: clientID, clientSecret: clientSecret)
                                    clientSecret = ""
                                    preferences.stockSettingsRevision += 1
                                    apiMessage = L10n.t("API keys saved")
                                }
                                .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(L10n.t("Remove API keys")) {
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
                if let apiMessage { Text(apiMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if preferences.stockQuoteSource == .toss {
                Section(L10n.t("My Toss holdings · model estimates")) {
                    Toggle(L10n.t("Show estimates for my actual holdings"),
                           isOn: $preferences.portfolioForecastEnabled)
                    if preferences.portfolioForecastEnabled {
                        Text(L10n.t("Read-only account access. Account numbers, quantities, and balances are not included in forecast history."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if portfolio.accounts.count > 1 {
                            Picker(L10n.t("Toss Securities account"), selection: $preferences.tossAccountSeq) {
                                Text(L10n.t("Select an account")).tag(0)
                                ForEach(portfolio.accounts) { account in
                                    Text(account.maskedNumber).tag(account.accountSeq)
                                }
                            }
                        } else if let account = portfolio.accounts.first {
                            LabeledContent(L10n.t("Toss Securities account"), value: account.maskedNumber)
                        }
                        if portfolio.loading { ProgressView(L10n.t("Loading holdings…")) }
                        if let message = portfolio.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(portfolio.holdings) { holding in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(holding.name.isEmpty ? holding.symbol : holding.name)
                                    .font(.headline)
                                Text("\(holding.marketCountry) · \(holding.symbol)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let estimate = portfolio.forecasts[holding.id] {
                                    let up = Int((estimate.riseProbability * 100).rounded())
                                    HStack(spacing: 16) {
                                        Text("\(L10n.t("Rise")) ≈\(up)%")
                                            .foregroundStyle(.green)
                                        Text("\(L10n.t("Fall")) ≈\(100 - up)%")
                                            .foregroundStyle(.red)
                                    }
                                    Text("\(L10n.t("Estimated close")): \(StockQuoteCodec.format(price: estimate.expectedClose, currency: holding.currency, locale: .current))")
                                        .font(.subheadline)
                                    Text("\(L10n.t("Model 80% range")): \(StockQuoteCodec.format(price: estimate.lowerClose, currency: holding.currency, locale: .current)) – \(StockQuoteCodec.format(price: estimate.upperClose, currency: holding.currency, locale: .current))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let record = portfolio.candidates.first(where: { $0.stockID == holding.stock?.id }) {
                                        DisclosureGroup(L10n.t("Prediction evidence")) {
                                            ForecastEvidenceView(record: record).padding(.vertical, 6)
                                        }
                                    }
                                } else if let reason = portfolio.reasons[holding.id] {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        Text(L10n.t("Experimental, uncalibrated model: 20–60 completed daily returns set volatility. Today's fresh price is the expected close; rise/fall odds assume zero drift until the regular close. Not an investment signal."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(L10n.t("Automatically record and evaluate forecasts"), isOn: $preferences.recordsStockForecasts)
                        Text(L10n.t("While this app is running, save one fresh prediction per stock 55–60 minutes before the regular close, even with Settings closed. Symbols, prices, dates, and model results are stored only on this Mac. Missed predictions are not backfilled."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.t("Save current predictions")) {
                            let saved = portfolio.saveCurrent()
                            forecastSaveMessage = portfolio.journal.errorMessage ?? (saved > 0
                                ? String(format: L10n.t("Saved %d predictions."), saved)
                                : L10n.t("Already saved today, or waiting for a fresh quote. Existing predictions are never replaced."))
                        }
                        .disabled(portfolio.candidates.isEmpty)
                        if let forecastSaveMessage {
                            Text(forecastSaveMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(L10n.t("Forecast history")) {
                Button(L10n.t("View forecast history and accuracy…")) { showsForecastHistory = true }
                Text(L10n.t("Compare saved predictions with the matching Toss daily close after the next local calendar date. Automatic and manual records are scored separately."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.t("Watchlist")) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.t("Add symbol"), systemImage: "plus.circle.fill")
                        .font(.headline)
                    HStack {
                        let prompt = L10n.t(preferences.stockQuoteSource == .toss
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
                        NotchItemAppearanceRow(preferences: preferences,
                            snapshot: StockBoard.snapshot(stock: stock, quote: nil, previousClose: nil,
                                                          name: nil, link: .idle, source: preferences.stockQuoteSource),
                            subtitle: preferences.stockQuoteSource.supports(stock)
                                ? "\(stock.market.rawValue.uppercased()) · \(stock.symbol)"
                                : L10n.t("Not supported by Finnhub"))
                        Button { step(stock.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(stocks.first?.id == stock.id)
                            .accessibilityLabel(L10n.t("Move \(stock.symbol) up"))
                        Button { step(stock.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(stocks.last?.id == stock.id)
                            .accessibilityLabel(L10n.t("Move \(stock.symbol) down"))
                        Button {
                            preferences.removeStockSymbol(stock.id)
                        } label: { Image(systemName: "minus.circle") }
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
            Section(L10n.t("Notch quote display")) {
                Stepper(value: $preferences.stockDisplayInterval, in: 1...10) {
                    Text(String(format: L10n.t("Switch every %d seconds"), preferences.stockDisplayInterval))
                }
            }
            if preferences.stockQuoteSource == .toss {
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

                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsForecastHistory) {
            StockForecastHistoryView(journal: portfolio.journal)
        }
        .onAppear { portfolio.setSettingsVisible(true) }
        .onDisappear { portfolio.setSettingsVisible(false) }
        .onChange(of: preferences.stockQuoteSource) { _, _ in
            apiMessage = nil
            message = nil
            showsFinnhubKeys = false
            showsTossKeys = false
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
