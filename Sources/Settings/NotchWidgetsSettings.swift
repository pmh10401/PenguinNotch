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

enum NotchItemCategory: String, CaseIterable, Identifiable {
    case ai, stocks, computer, widgets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ai: return L10n.t("AI subscriptions")
        case .stocks: return L10n.t("Stocks")
        case .computer: return L10n.t("Computer monitoring")
        case .widgets: return L10n.t("Daily widgets")
        }
    }
    func contains(_ snapshot: ProviderSnapshot) -> Bool {
        switch snapshot.kind {
        case .usage, .localRuntime: return self == .ai
        case .stocks: return self == .stocks
        case .system: return self == .computer
        case .calendar, .weather, .todo: return self == .widgets
        }
    }
}

struct NotchOrderSettings: View {
    @ObservedObject var preferences: Preferences
    let snapshots: [ProviderSnapshot]
    @State private var category: NotchItemCategory?

    private var allOrdered: [ProviderSnapshot] {
        ProviderOrder.arrange(snapshots, by: preferences.providerOrder, id: \.id)
    }
    private var ordered: [ProviderSnapshot] {
        allOrdered.filter { category?.contains($0) ?? true }
    }

    var body: some View {
        Text(L10n.t("Choose what appears in the notch. Hidden items keep their data, color and position. Drag rows or use the arrows to reorder."))
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Picker(L10n.t("Category"), selection: $category) {
                Text(L10n.t("All items")).tag(nil as NotchItemCategory?)
                ForEach(NotchItemCategory.allCases) { item in
                    Text(item.title).tag(Optional(item))
                }
            }
            Button(L10n.t("Group by category")) {
                let grouped = NotchItemCategory.allCases.flatMap { item in allOrdered.filter(item.contains) }
                preferences.providerOrder = ProviderOrder.keepingHiddenSlots(grouped.map(\.id), in: preferences.providerOrder)
            }
        }
        if ordered.isEmpty {
            Text(L10n.t("No items in this category."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if !preferences.showsSystemUsage, category == nil || category == .computer {
            Text(L10n.t("Hardware switches are paused. Enable monitoring on the Computer monitoring page."))
                .font(.caption).foregroundStyle(.secondary)
        }
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
        let completeOrder = ProviderOrder.keepingHiddenSlots(allOrdered.map(\.id), in: preferences.providerOrder)
        preferences.providerOrder = ProviderOrder.keepingHiddenSlots(ids, in: completeOrder)
        return true
    }
}
