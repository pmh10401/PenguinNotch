import SwiftUI

struct StockSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var finnhubKey = ""
    @State private var symbol = ""
    @State private var message: String?
    @State private var apiMessage: String?
    @State private var showsFinnhubKeys = false
    @State private var showsTossKeys = false

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
                ForEach(WatchedStock.parseList(preferences.stockSymbols)) { stock in
                    HStack(spacing: 12) {
                        NotchItemAppearanceRow(preferences: preferences,
                            snapshot: StockBoard.snapshot(stock: stock, quote: nil, previousClose: nil,
                                                          name: nil, link: .idle, source: preferences.stockQuoteSource),
                            subtitle: preferences.stockQuoteSource.supports(stock)
                                ? "\(stock.market.rawValue.uppercased()) · \(stock.symbol)"
                                : L10n.t("Not supported by Finnhub"))
                        Button {
                            preferences.removeStockSymbol(stock.id)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L10n.t("Remove \(stock.symbol)"))
                            .accessibilityLabel(L10n.t("Remove \(stock.symbol)"))
                    }
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
