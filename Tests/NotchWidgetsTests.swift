import SwiftUI
import XCTest
@testable import PenguinNotch

final class NotchWidgetsTests: XCTestCase {
    @MainActor
    func testCategoryReorderingPreservesOtherItemsAndUnseenSlots() {
        let ai = Fixtures.snapshots()[0]
        let cpu = SystemUsageReading().snapshots[0]
        let stocks = StockBoard.orderSnapshots(stored: ["AAPL", "SOXL"])
        let calendar = CalendarMonth.snapshot()
        let all = [ai, stocks[0], cpu, stocks[1], calendar]
        for snapshot in all {
            XCTAssertEqual(NotchItemCategory.allCases.filter { $0.contains(snapshot) }.count, 1)
        }
        let reversedStocks = all.filter(NotchItemCategory.stocks.contains).reversed().map(\.id)
        let remembered = [ai.id, stocks[0].id, "temporarily-absent", cpu.id, stocks[1].id]
        let completeOrder = ProviderOrder.keepingHiddenSlots(all.map(\.id), in: remembered)
        XCTAssertEqual(ProviderOrder.keepingHiddenSlots(reversedStocks, in: completeOrder),
                       [ai.id, stocks[1].id, "temporarily-absent", cpu.id, stocks[0].id, calendar.id])
    }

    static let weatherJSON = Data(#"{"timezone":"Asia/Seoul","current":{"time":1790035200,"temperature_2m":23.4,"weather_code":61,"is_day":1,"relative_humidity_2m":65,"wind_speed_10m":2.3},"daily":{"time":[1790002800],"temperature_2m_min":[18],"temperature_2m_max":[26],"precipitation_probability_max":[75]}}"#.utf8)
    static let city = WeatherLocation(id: 1835848, name: "Seoul", latitude: 37.566, longitude: 126.978)

    func testCalendarUsesMonthBoundariesLeapYearsAndTheChosenWeekStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        for (year, month, count) in [(2024, 2, 29), (2025, 2, 28), (2026, 3, 31), (2026, 12, 31)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 15)))
            let grid = CalendarMonth(containing: date, calendar: calendar)
            XCTAssertEqual(grid.days.count, 42)
            XCTAssertEqual(Set(grid.days).count, 42)
            XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(grid.days.first)), 2)
            XCTAssertEqual(grid.days.filter { calendar.isDate($0, equalTo: date, toGranularity: .month) }.count, count)
            for (previous, next) in zip(grid.days, grid.days.dropFirst()) {
                XCTAssertEqual(calendar.dateComponents([.day], from: previous, to: next).day, 1)
            }
        }
        let beforeDST = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23)))
        let afterDST = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 1)))
        XCTAssertEqual(CalendarMonth.dayOffset(from: beforeDST, to: afterDST, calendar: calendar), 2)
        XCTAssertEqual(CalendarMonth.dayOffset(from: afterDST, to: beforeDST, calendar: calendar), -2)
        XCTAssertEqual(CalendarMonth.isoDate(beforeDST, timeZone: calendar.timeZone), "2026-03-07")
        XCTAssertEqual(CalendarMonth.dayDistanceText(0), "Today")
        XCTAssertEqual(CalendarMonth.dayDistanceText(1), "In 1 day")
        XCTAssertEqual(CalendarMonth.dayDistanceText(2), "In 2 days")
        XCTAssertEqual(CalendarMonth.dayDistanceText(-1), "1 day ago")
        XCTAssertEqual(CalendarMonth.dayDistanceText(-3), "3 days ago")
        XCTAssertEqual(CalendarMonth.yearProgressText(week: 12, daysLeft: 0), "Week 12 · 0 days left this year")
        XCTAssertEqual(CalendarMonth.yearProgressText(week: 12, daysLeft: 1), "Week 12 · 1 day left this year")
        XCTAssertEqual(CalendarMonth.yearProgressText(week: 12, daysLeft: 40), "Week 12 · 40 days left this year")
        XCTAssertEqual(L10n.t("Sampling…", locale: Locale(identifier: "ko")), "측정 중…")
        XCTAssertEqual(L10n.t("In \(2) days", locale: Locale(identifier: "ko")), "2일 후")
        XCTAssertEqual(L10n.t("In 1 day", locale: Locale(identifier: "ko")), "1일 후")
        XCTAssertEqual(L10n.t("\("12")% active", locale: Locale(identifier: "ko")), "12% 사용 중")
        XCTAssertEqual(L10n.t("Week \(12) · \(40) days left this year", locale: Locale(identifier: "ko")), "12주차 · 올해 40일 남음")
        XCTAssertEqual(L10n.t("Core \(3)", locale: Locale(identifier: "fr")), "Cœur 3")
        XCTAssertEqual(L10n.t("Complete \("정리")", locale: Locale(identifier: "ko")), "정리 완료")
        XCTAssertEqual(L10n.t("Today", locale: Locale(identifier: "uz")), "Bugun")
    }

    func testWeatherHoverExtrasRequireValidCompleteForecasts() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.weatherJSON) as? [String: Any])
        var current = try XCTUnwrap(json["current"] as? [String: Any])
        current["apparent_temperature"] = 26.1
        json["current"] = current
        let base = try WeatherClient.decode(Self.weatherJSON)
        let now = base.measuredAt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var daily = try XCTUnwrap(json["daily"] as? [String: Any])
        daily["sunrise"] = [try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 20, second: 0, of: now)).timeIntervalSince1970]
        daily["sunset"] = [try XCTUnwrap(calendar.date(bySettingHour: 18, minute: 30, second: 0, of: now)).timeIntervalSince1970]
        daily["uv_index_max"] = [7.2]
        json["daily"] = daily
        let times = (1...6).map { now.addingTimeInterval(Double($0) * 3600).timeIntervalSince1970 }
        json["hourly"] = ["time": times, "precipitation_probability": [10, 30, 80, 20, 10, 0]]
        let reading = try WeatherClient.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(reading.apparentTemperature, 26.1)
        XCTAssertEqual(reading.upcomingRainPeak(now: now)?.probability, 80)
        XCTAssertEqual(reading.upcomingRainPeak(now: now)?.end, now.addingTimeInterval(3 * 3600))
        let ids = Set(reading.snapshot(location: Self.city, now: now).windows.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["feels-like", "rain-ahead", "rain-hour", "sun", "uv"]))
        let tomorrow = Set(reading.snapshot(location: Self.city, now: now.addingTimeInterval(86400)).windows.map(\.id))
        XCTAssertTrue(tomorrow.isDisjoint(with: ["forecast", "rain", "sun", "uv", "rain-ahead"]))
        json["hourly"] = ["time": times, "precipitation_probability": [10, 30, NSNull(), 20, 10, 0]]
        XCTAssertNil(try WeatherClient.decode(JSONSerialization.data(withJSONObject: json)).upcomingRainPeak(now: now),
                     "Missing hourly data must not become a low-rain forecast")
    }

    func testWeatherDecodingUsesRealUnitsAndFlagsOldOrFailedReadings() throws {
        let reading = try WeatherClient.decode(Self.weatherJSON)
        XCTAssertEqual(reading.temperature, 23.4)
        XCTAssertEqual(reading.wind, 2.3)
        XCTAssertEqual(reading.condition.glyph, .weatherRain)
        let fresh = reading.snapshot(location: Self.city, now: reading.measuredAt)
        XCTAssertEqual(fresh.headlineText, "23°")
        XCTAssertEqual(fresh.windows.first { $0.id == "temperature" }?.detail, "23.4°C")
        let previousLocale = L10n.testLocale
        L10n.testLocale = Locale(identifier: "de_DE")
        defer { L10n.testLocale = previousLocale }
        XCTAssertEqual(reading.snapshot(location: Self.city, now: reading.measuredAt)
            .windows.first { $0.id == "temperature" }?.detail, "23,4°C")
        XCTAssertNil(fresh.usedFraction)
        XCTAssertTrue(fresh.hasReading)
        XCTAssertEqual(fresh.kind, .weather)
        XCTAssertFalse(fresh.status.isStale)
        XCTAssertTrue(reading.snapshot(location: Self.city, now: reading.measuredAt.addingTimeInterval(1801)).status.isStale)
        XCTAssertTrue(reading.snapshot(location: Self.city, now: reading.measuredAt, failed: true).status.isStale)
        XCTAssertTrue(fresh.windows.contains { $0.id == "forecast" })
        XCTAssertFalse(reading.snapshot(location: Self.city, now: reading.measuredAt.addingTimeInterval(86400))
            .windows.contains { $0.id == "forecast" || $0.id == "rain" }, "Yesterday's forecast must not be called today's")
    }

    func testWeatherRejectsMissingAndInvalidMeasurements() throws {
        XCTAssertThrowsError(try WeatherClient.decode(Data(#"{"current":{"temperature_2m":null}}"#.utf8)))
        let invalid = String(decoding: Self.weatherJSON, as: UTF8.self).replacingOccurrences(of: "23.4", with: "234")
        XCTAssertThrowsError(try WeatherClient.decode(Data(invalid.utf8)))
        let optionalInvalid = String(decoding: Self.weatherJSON, as: UTF8.self)
            .replacingOccurrences(of: "[18]", with: "[null]")
            .replacingOccurrences(of: "[75]", with: "[175]")
        let reading = try WeatherClient.decode(Data(optionalInvalid.utf8))
        XCTAssertNil(reading.low)
        XCTAssertNil(reading.high)
        XCTAssertNil(reading.rainChance)
    }

    func testWeatherRequestsHaveExplicitUnitsAndValidatedCityCoordinates() throws {
        let url = try WeatherClient.forecastURL(for: Self.city)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(values["wind_speed_unit"], "ms")
        XCTAssertEqual(values["temperature_unit"], "celsius")
        XCTAssertEqual(values["timezone"], "auto")
        XCTAssertEqual(values["timeformat"], "unixtime")
        XCTAssertThrowsError(try WeatherClient.forecastURL(for: .init(id: 1, name: "Bad", latitude: 91, longitude: 0)))
    }

    func testAccountReorderingPreservesWidgetSlots() {
        XCTAssertEqual(ProviderOrder.replacingSubset(["codex", "claude"],
            in: ["widget-calendar", "claude", "system-cpu", "codex", "widget-weather"]),
            ["widget-calendar", "codex", "system-cpu", "claude", "widget-weather"])
        XCTAssertEqual(ProviderOrder.replacingSubset(["new", "codex"], in: []), ["new", "codex"])
        XCTAssertEqual(ProviderOrder.replacingSubset(["codex", "claude"],
            in: ["widget-calendar", "claude", "claude-work", "system-cpu", "codex"]),
            ["widget-calendar", "codex", "system-cpu", "claude", "claude-work"])
        let hiddenCalendar = ["codex", "widget-calendar", "system-cpu", "widget-weather"]
        XCTAssertEqual(ProviderOrder.keepingHiddenSlots(["system-cpu", "codex", "widget-weather"], in: hiddenCalendar),
                       ["system-cpu", "widget-calendar", "codex", "widget-weather"])
        XCTAssertEqual(ProviderOrder.keepingHiddenSlots(["system-cpu", "new", "codex"], in: hiddenCalendar),
                       ["system-cpu", "widget-calendar", "new", "widget-weather", "codex"])
        XCTAssertEqual(ProviderOrder.keepingHiddenSlots([], in: hiddenCalendar), hiddenCalendar)
        XCTAssertEqual(ProviderOrder.keepingHiddenSlots(["codex", "widget-calendar"], in: []),
                       ["codex", "widget-calendar"])
    }

    func testLiveWeatherWhenRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PENGUINNOTCH_LIVE_WEATHER_TEST"] == "1")
        let cities = try await WeatherClient.search("Seoul")
        let city = try XCTUnwrap(cities.first)
        let reading = try await WeatherClient.fetch(city)
        XCTAssertLessThan(abs(reading.measuredAt.timeIntervalSinceNow), 3600)
        XCTAssertTrue(reading.snapshot(location: city).hasReading)
        XCTAssertNotNil(reading.forecastDay)
        XCTAssertNotNil(reading.apparentTemperature)
        XCTAssertNotNil(reading.sunrise)
        XCTAssertNotNil(reading.sunset)
        XCTAssertNotNil(reading.uvIndex)
        XCTAssertNotNil(reading.upcomingRainPeak(now: reading.measuredAt))
        print("LIVE_WEATHER_OK \(city.name): \(reading.temperature)°C")
    }
}

@MainActor
final class NotchWidgetsIntegrationTests: XCTestCase {
    func testItemVisibilityPersistsAcrossRefreshAndDisplaysWithoutLosingData() throws {
        let name = "NotchVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.hiddenNotchItems.isEmpty)
        preferences.addTodo("Keep this task")
        preferences.systemUsageColors["system-cpu"] = .purple
        let account = try XCTUnwrap(Fixtures.snapshots().first)
        let runtime = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
            fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
            localRuntime: LocalRuntimeReading(models: [
                .init(name: "model-a", memoryBytes: nil, contextLength: nil, quantizationLevel: nil),
                .init(name: "model-b", memoryBytes: nil, contextLength: nil, quantizationLevel: nil)
            ]))
        let localID = try XCTUnwrap(runtime.notchSnapshots.first?.id)
        preferences.providerOrder = ["widget-todo", "system-cpu", localID, account.id]
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        let widgets = NotchWidgetsMonitor(preferences: preferences)
        let visibility = preferences.$hiddenNotchItems.sink { fleet.apply(hiddenItems: $0) }
        let updates = widgets.$snapshots.sink { fleet.setWidgetSnapshots($0, colors: preferences.systemUsageColors) }
        defer { visibility.cancel(); updates.cancel(); widgets.stop(); fleet.stop() }
        fleet.apply(order: preferences.providerOrder)
        fleet.setSnapshots([account, runtime])
        fleet.setSystemSnapshots(SystemUsageTests.reading.snapshots, colors: preferences.systemUsageColors)
        let original = fleet.menuModel.snapshots
        fleet.menuModel.hoveredIndex = original.firstIndex { $0.id == "system-cpu" }
        let hidden = ["system-cpu", "system-network", account.id, localID]
        for id in hidden { preferences.setNotchItemVisible(false, id: id) }
        XCTAssertNil(fleet.menuModel.hoveredSnapshot)
        fleet.setSnapshots([account, runtime])
        fleet.setSystemSnapshots(SystemUsageTests.reading.snapshots, colors: preferences.systemUsageColors)
        fleet.apply(order: preferences.providerOrder)
        XCTAssertTrue(Set(fleet.menuModel.snapshots.map(\.id)).isDisjoint(with: hidden))
        for id in ["widget-calendar", "widget-weather", "widget-todo"] {
            preferences.setNotchItemVisible(false, id: id)
            XCTAssertFalse(preferences.isNotchItemVisible(id))
            XCTAssertFalse(fleet.menuModel.snapshots.contains { $0.id == id })
        }
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.hiddenNotchItems, Set(hidden))
        XCTAssertFalse(reloaded.showsCalendar || reloaded.showsWeather || reloaded.showsTodo)
        XCTAssertEqual(reloaded.todoItems, preferences.todoItems)
        XCTAssertEqual(reloaded.systemUsageColors, preferences.systemUsageColors)
        XCTAssertEqual(reloaded.providerOrder, preferences.providerOrder)
        XCTAssertEqual(reloaded.connectedProviders, preferences.connectedProviders)
        fleet.reconcileForTesting()
        XCTAssertFalse(fleet.controllersForTesting.isEmpty)
        for controller in fleet.controllersForTesting {
            XCTAssertEqual(controller.model.snapshots, fleet.menuModel.snapshots)
        }
        for snapshot in original { preferences.setNotchItemVisible(true, id: snapshot.id) }
        XCTAssertEqual(fleet.menuModel.snapshots.map(\.id), original.map(\.id))
        XCTAssertEqual(fleet.menuModel.snapshots.first { $0.id == "system-cpu" }?.systemColor, .purple)
        for snapshot in original { preferences.setNotchItemVisible(false, id: snapshot.id) }
        XCTAssertTrue(fleet.menuModel.snapshots.isEmpty)
        preferences.setNotchItemVisible(true, id: "system-cpu")
        XCTAssertEqual(fleet.menuModel.snapshots.map(\.id), ["system-cpu"])
    }

    func testGlobalOrderReachesEveryDisplayAndSurvivesRefreshWithHover() throws {
        let fleet = NotchFleet(scope: .allDisplays, edge: .right)
        defer { fleet.stop() }
        let widgets = [CalendarMonth.snapshot(), NotchWidgetsMonitor.weatherPlaceholder()]
        let models = ["model-a", "model-b"].map {
            LocalRuntimeReading.Model(name: $0, memoryBytes: nil, contextLength: nil, quantizationLevel: nil)
        }
        var runtime = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
                                       fidelity: .official, status: .ok, windows: [], kind: .localRuntime,
                                       localRuntime: LocalRuntimeReading(models: models))
        let localIDs = runtime.notchSnapshots.map(\.id)
        let order = ["widget-weather", localIDs[1], "system-cpu", "widget-calendar", localIDs[0]]
        fleet.apply(order: order)
        fleet.setSnapshots(Fixtures.snapshots() + [runtime])
        fleet.setWidgetSnapshots(widgets, colors: ["widget-calendar": .green])
        fleet.setSystemSnapshots(SystemUsageTests.reading.snapshots, colors: [:])
        XCTAssertEqual(Array(fleet.menuModel.snapshots.prefix(5).map(\.id)), order)
        runtime.localRuntime = LocalRuntimeReading(models: models.reversed())
        fleet.setSnapshots(Fixtures.snapshots() + [runtime])
        XCTAssertEqual(Array(fleet.menuModel.snapshots.prefix(5).map(\.id)), order)
        fleet.menuModel.hoveredIndex = 3
        fleet.apply(order: ["widget-calendar", "system-cpu", "widget-weather"])
        fleet.setSystemSnapshots(SystemUsageTests.reading.snapshots, colors: [:])
        XCTAssertEqual(fleet.menuModel.hoveredSnapshot?.id, "widget-calendar")
        XCTAssertEqual(fleet.menuModel.hoveredIndex, 0)
        fleet.reconcileForTesting()
        XCTAssertFalse(fleet.controllersForTesting.isEmpty)
        for controller in fleet.controllersForTesting {
            XCTAssertEqual(controller.model.snapshots, fleet.menuModel.snapshots)
        }
    }

    func testCalendarAndWeatherPreferencesPersistWithoutResettingExistingSettings() throws {
        let name = "NotchWidgets.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsWeather = false
        preferences.systemUsageColors["system-cpu"] = .purple
        preferences.weatherLocation = NotchWidgetsTests.city
        preferences.providerOrder = ["widget-calendar", "system-cpu"]
        let restored = Preferences(defaults: defaults)
        XCTAssertEqual(restored.weatherLocation, NotchWidgetsTests.city)
        XCTAssertEqual(restored.systemUsageColors["system-cpu"], .purple)
        XCTAssertEqual(restored.providerOrder, ["widget-calendar", "system-cpu"])
        let monitor = NotchWidgetsMonitor(preferences: restored)
        defer { monitor.stop() }
        XCTAssertEqual(monitor.snapshots.map(\.id), ["widget-calendar", "widget-todo"])
        restored.showsCalendar = false
        XCTAssertEqual(monitor.snapshots.map(\.id), ["widget-todo"])
        restored.showsTodo = false
        XCTAssertTrue(monitor.snapshots.isEmpty)
        restored.weatherLocation = nil
        restored.showsWeather = true
        XCTAssertEqual(monitor.snapshots.map(\.id), ["widget-weather"])
        XCTAssertFalse(try XCTUnwrap(monitor.snapshots.first).hasReading)
    }

    func testCalendarLayoutFitsAllEdgesAndRendersTheMonth() throws {
        let now = Date(timeIntervalSince1970: 1790035200)
        let calendar = CalendarMonth.snapshot(now: now)
        var weatherReading = try WeatherClient.decode(NotchWidgetsTests.weatherJSON)
        weatherReading.apparentTemperature = 26.1
        weatherReading.uvIndex = 7.2
        weatherReading.sunrise = now.addingTimeInterval(-7200)
        weatherReading.sunset = now.addingTimeInterval(10 * 3600)
        weatherReading.hourlyRain = (1...6).map { .init(end: now.addingTimeInterval(Double($0) * 3600), probability: 80) }
        let weather = weatherReading.snapshot(location: NotchWidgetsTests.city, now: now)
        let model = NotchViewModel()
        model.screenSize = CGSize(width: 1440, height: 900)
        model.sizeScale = NotchSize.small.scale
        model.updateSnapshots(Fixtures.snapshots() + SystemUsageTests.reading.snapshots + [calendar, weather])
        for edge in NotchEdge.allCases {
            model.edge = edge
            XCTAssertEqual(model.cardHeight(for: calendar), NotchLayout.calendarCardHeight)
            // Transparent panel margins can extend offscreen; the cells and card cannot.
            XCTAssertLessThanOrEqual(model.shapeLength * model.sizeScale,
                                     edge.isVertical ? model.screenSize.height : model.screenSize.width)
            XCTAssertLessThanOrEqual(model.cardHeight(for: calendar), model.screenSize.height)
        }
        let renderer = ImageRenderer(content: HStack(alignment: .top, spacing: 20) {
            CalendarCard(now: now, direction: .leading)
            TooltipCard(snapshot: weather, now: now)
        }.padding(20).environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/penguinnotch-widgets-preview.png"))
    }

    func testTodoPersistsCarriesUnfinishedTasksAndUpdatesTheNotch() throws {
        let name = "Todo.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsWeather = false
        let now = Date()
        XCTAssertFalse(preferences.addTodo(" \n "))
        XCTAssertFalse(preferences.addTodo(String(repeating: "a", count: 201)))
        XCTAssertTrue(preferences.addTodo("  오늘 작업 정리하기  ", now: now))
        XCTAssertTrue(preferences.addTodo("확인할 자료 읽고 중요한 내용 메모하기", now: now))
        let first = try XCTUnwrap(preferences.todoItems.first)
        XCTAssertEqual(first.title, "오늘 작업 정리하기")
        let monitor = NotchWidgetsMonitor(preferences: preferences)
        defer { monitor.stop() }
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        fleet.todoPreferences = preferences
        let subscription = monitor.$snapshots.sink { fleet.setWidgetSnapshots($0, colors: ["widget-todo": .green]) }
        defer { subscription.cancel(); fleet.stop() }
        fleet.menuModel.hoveredIndex = fleet.menuModel.snapshots.firstIndex { $0.id == "widget-todo" }
        preferences.toggleTodo(first.id, now: now)
        let completed = try XCTUnwrap(fleet.menuModel.hoveredSnapshot)
        XCTAssertEqual(completed.headlineText, "1/2")
        XCTAssertEqual(completed.ringFraction, 0.5)
        XCTAssertEqual(completed.systemColor, .green)
        XCTAssertEqual(completed.bandOverride, .ample)
        XCTAssertEqual(Preferences(defaults: defaults).todoItems, preferences.todoItems)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        XCTAssertEqual(TodoItem.today(preferences.todoItems, now: tomorrow).map(\.title), ["확인할 자료 읽고 중요한 내용 메모하기"])
        XCTAssertEqual(preferences.todoItems.count, 2, "Rollover never deletes history")
        preferences.toggleTodo(first.id, now: tomorrow)
        XCTAssertEqual(TodoItem.today(preferences.todoItems, now: tomorrow).count, 2)
        preferences.toggleTodo(first.id, now: now)
        fleet.reconcileForTesting()
        XCTAssertFalse(fleet.controllersForTesting.isEmpty)
        for controller in fleet.controllersForTesting {
            XCTAssertTrue(controller.model.todoPreferences === preferences)
            XCTAssertEqual(controller.model.cardHeight(for: completed), NotchLayout.todoCardHeight)
        }
        let renderer = ImageRenderer(content: TodoCard(preferences: preferences, now: now, direction: .leading)
            .padding(20).background(Color.black)
            .environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/penguinnotch-todo-preview.png"))
        preferences.removeTodo(first.id)
        XCTAssertEqual(Preferences(defaults: defaults).todoItems.count, 1)
        preferences.showsTodo = false
        XCTAssertFalse(monitor.snapshots.contains { $0.id == "widget-todo" })
        XCTAssertFalse(Preferences(defaults: defaults).showsTodo)
        XCTAssertEqual(TodoItem.snapshot([]).headlineText, "0/0")
    }
}
