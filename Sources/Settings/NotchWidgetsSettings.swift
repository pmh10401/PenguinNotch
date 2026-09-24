import SwiftUI

struct WeatherSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var query = ""
    @State private var results: [WeatherLocation] = []
    @State private var message: String?
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        if let location = preferences.weatherLocation {
            LabeledContent(L10n.t("Weather city"), value: location.title)
        }
        HStack {
            TextField(L10n.t("Search city"), text: $query)
                .onSubmit(search)
            Button(L10n.t("Search"), action: search)
                .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            if searching { ProgressView().controlSize(.small) }
        }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searching = false
            results = []
            message = nil
        }
        ForEach(results) { location in
            Button {
                preferences.weatherLocation = location
                results = []
                message = nil
            } label: {
                HStack { Text(location.title); Spacer(); Image(systemName: "plus.circle") }
            }
        }
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        HStack(spacing: 4) {
            Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
            Text("·")
            Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!)
            Text(L10n.t("· Celsius · Refreshes every 15 minutes"))
        }
        .font(.caption)
        .onDisappear { searchTask?.cancel() }
    }

    private func search() {
        searchTask?.cancel()
        let requested = query
        searching = true
        message = nil
        searchTask = Task { @MainActor in
            do {
                let found = try await WeatherClient.search(requested)
                guard !Task.isCancelled, query == requested else { return }
                results = found
                if found.isEmpty { message = L10n.t("No matching city. Try a nearby city or its English name.") }
            } catch {
                guard !Task.isCancelled else { return }
                message = L10n.t("City search failed. Check the connection and try again.")
            }
            searching = false
        }
    }
}

struct StockSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var symbol = ""
    @State private var message: String?

    var body: some View {
        Text(L10n.t("Realtime trades from Toss Securities. Turn Stocks on under Notch items and order. Register this Mac's public IP under WTS → Settings → Open API → Allowed IPs. The client secret stays in the Keychain."))
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
                message = L10n.t("API keys saved")
            }
            .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.t("Remove API keys")) {
                TossCredentials.clear()
                clientID = ""
                clientSecret = ""
                preferences.stockSettingsRevision += 1
                message = nil
            }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Add symbol"), systemImage: "plus.circle.fill")
                .font(.headline)
            HStack {
                TextField("Company name or symbol · 삼성전자, 005930, AAPL", text: $symbol)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(add)
                Button(L10n.t("Add symbol"), action: add)
                    .buttonStyle(SettingsButtonStyle(kind: .prominent))
                    .disabled(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if WatchedStock.parse(symbol) == nil {
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
        ForEach(WatchedStock.parseList(preferences.stockSymbols)) { stock in
            HStack {
                Text(stock.market == .kr ? "KR \(stock.symbol)" : "US \(stock.symbol)")
                Spacer()
                Button {
                    preferences.removeStockSymbol(stock.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.t("Remove \(stock.symbol)"))
            }
        }
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }

    private func add() {
        add(symbol)
    }

    private func add(_ input: String) {
        guard let stock = KoreanStockDirectory.shared.resolve(input) else {
            message = "Company not found. Select a match or enter a Korean stock code or US ticker."
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

struct NotchOrderSettings: View {
    @ObservedObject var preferences: Preferences
    let snapshots: [ProviderSnapshot]

    private var ordered: [ProviderSnapshot] {
        ProviderOrder.arrange(snapshots, by: preferences.providerOrder, id: \.id)
    }

    var body: some View {
        Text(L10n.t("Choose what appears in the notch. Hidden items keep their data, color and position. Drag rows or use the arrows to reorder."))
            .font(.caption).foregroundStyle(.secondary)
        ForEach(ordered) { snapshot in
            let title = snapshot.localModel?.name ?? snapshot.displayName
            HStack {
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    ProviderGlyphView(glyph: snapshot.glyph, size: 15)
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .draggable(snapshot.id)
                .help(L10n.t("Drag to reorder"))
                Spacer(minLength: 8)
                Toggle(L10n.t("Show \(title) in notch"), isOn: Binding(
                    get: { preferences.isNotchItemVisible(snapshot.id) },
                    set: { preferences.setNotchItemVisible($0, id: snapshot.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(snapshot.kind == .system && !preferences.showsSystemUsage)
                Button { step(snapshot.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(ordered.first?.id == snapshot.id)
                    .accessibilityLabel(L10n.t("Move \(title) up"))
                Button { step(snapshot.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(ordered.last?.id == snapshot.id)
                    .accessibilityLabel(L10n.t("Move \(title) down"))
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                guard ids.count == 1, let moved = ids.first else { return false }
                return move(moved, onto: snapshot.id)
            }
        }
    }

    private func step(_ id: String, by offset: Int) {
        let ids = ordered.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        _ = move(id, onto: ids[index + offset])
    }

    private func move(_ id: String, onto target: String) -> Bool {
        var ids = ordered.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return false }
        ids.insert(ids.remove(at: from), at: to)
        preferences.providerOrder = ProviderOrder.keepingHiddenSlots(ids, in: preferences.providerOrder)
        return true
    }
}
