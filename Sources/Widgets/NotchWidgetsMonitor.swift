import AppKit
import Combine

@MainActor
final class NotchWidgetsMonitor: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    private var showsCalendar = false
    private var showsWeather = false
    private var showsTodo = false
    private var todoItems: [TodoItem] = []
    private var location: WeatherLocation?
    private var reading: WeatherReading?
    private var weatherFailed = false
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences) {
        preferences.$showsTodo.combineLatest(preferences.$todoItems)
            .sink { [weak self] shows, items in
                self?.showsTodo = shows
                self?.todoItems = items
                self?.publish()
            }.store(in: &cancellables)
        preferences.$showsCalendar.combineLatest(preferences.$showsWeather, preferences.$weatherLocation)
            .sink { [weak self] calendar, weather, location in
                guard let self else { return }
                let changed = self.showsWeather != weather || self.location != location
                self.showsCalendar = calendar
                self.showsWeather = weather
                self.location = location
                if changed {
                    self.reading = nil
                    self.weatherFailed = false
                    self.startWeather()
                }
                self.publish()
            }.store(in: &cancellables)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish(); self?.startWeather() }
            .store(in: &cancellables)
    }

    deinit { task?.cancel() }

    func stop() {
        task?.cancel()
        task = nil
        cancellables.removeAll()
    }

    func refreshWeather() { startWeather() }

    private func startWeather() {
        task?.cancel()
        task = nil
        guard showsWeather, let location, location.isValid else { return }
        task = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                do {
                    let reading = try await WeatherClient.fetch(location)
                    guard !Task.isCancelled, self?.location == location else { return }
                    self?.reading = reading
                    self?.weatherFailed = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.weatherFailed = true
                }
                self?.publish()
                do { try await Task.sleep(for: .seconds(15 * 60)) }
                catch { return }
            }
        }
    }

    private func publish() {
        var next = showsCalendar ? [CalendarMonth.snapshot()] : []
        if showsWeather {
            if let reading, let location {
                next.append(reading.snapshot(location: location, failed: weatherFailed))
            } else {
                next.append(Self.weatherPlaceholder(location: location, failed: weatherFailed))
            }
        }
        if showsTodo { next.append(TodoItem.snapshot(todoItems)) }
        if next != snapshots { snapshots = next }
    }

    static func weatherPlaceholder(location: WeatherLocation? = nil, failed: Bool = false) -> ProviderSnapshot {
        let message = location == nil ? L10n.t("Choose a weather city in Settings → Appearance.")
            : failed ? L10n.t("Weather is unavailable. It will retry automatically.") : L10n.t("Loading weather…")
        return ProviderSnapshot(id: "widget-weather", displayName: location?.name ?? L10n.t("Weather"),
                                glyph: .weatherPartlyCloudy, fidelity: .official,
                                status: .unsupported(message), windows: [], kind: .weather, plan: "Open-Meteo")
    }
}
