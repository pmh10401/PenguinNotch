import SwiftUI

struct NotchItemAppearanceRow: View {
    @ObservedObject var preferences: Preferences
    let snapshot: ProviderSnapshot
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ProviderGlyphView(glyph: snapshot.glyph, size: 18)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.displayName).lineLimit(2)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Picker(L10n.t("Color"), selection: Binding<AccentColorChoice?>(
                get: { preferences.systemUsageColors[snapshot.id] },
                set: { preferences.systemUsageColors[snapshot.id] = $0 }
            )) {
                Text(L10n.t("Automatic")).tag(nil as AccentColorChoice?)
                ForEach(AccentColorChoice.allCases) { choice in
                    Text(choice.title).tag(Optional(choice))
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .accessibilityLabel("\(snapshot.displayName), \(L10n.t("Color"))")
            Toggle(L10n.t("Show \(snapshot.displayName) in notch"), isOn: Binding(
                get: { preferences.isNotchItemVisible(snapshot.id) },
                set: { preferences.setNotchItemVisible($0, id: snapshot.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled((snapshot.kind == .system && !preferences.showsSystemUsage)
                      || (snapshot.kind == .stocks && !preferences.showsStocks))
        }
    }
}

struct SystemMonitoringSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("Enable system monitoring"), isOn: $preferences.showsSystemUsage)
                Text(L10n.t("Samples every second. Turn monitoring off to stop collection; your meter choices and colors are kept."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.t("Hardware meters")) {
                Text(L10n.t("Choose a color and switch each meter on or off."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(SystemUsageReading().snapshots) { snapshot in
                    NotchItemAppearanceRow(preferences: preferences, snapshot: snapshot)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DailyWidgetSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section(L10n.t("Calendar")) {
                NotchItemAppearanceRow(preferences: preferences, snapshot: CalendarMonth.snapshot())
                Text(L10n.t("See today’s date and hover to open the monthly calendar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.t("Weather")) {
                NotchItemAppearanceRow(preferences: preferences, snapshot: NotchWidgetsMonitor.weatherPlaceholder())
                WeatherSettings(preferences: preferences)
            }
            Section(L10n.t("Today’s tasks")) {
                NotchItemAppearanceRow(preferences: preferences, snapshot: TodoItem.snapshot(preferences.todoItems))
                Text(L10n.t("Hover over TODO to add tasks, mark them done or remove them. Unfinished tasks carry over to tomorrow."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
