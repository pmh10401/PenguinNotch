import Foundation

struct WeatherLocation: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    var admin1: String?
    var country: String?

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var title: String {
        [name, admin1 == name ? nil : admin1, country].compactMap { $0?.nonEmptyPlan }.joined(separator: ", ")
    }
}

struct WeatherReading: Equatable {
    struct RainHour: Equatable {
        /// Probability for the hour ending at this time (Open-Meteo semantics).
        let end: Date
        let probability: Double
    }
    let measuredAt: Date
    let temperature: Double
    let code: Int
    let isDay: Bool
    let humidity: Double?
    let wind: Double?
    let low: Double?
    let high: Double?
    let rainChance: Double?
    let forecastDay: Date?
    let timeZoneIdentifier: String
    var apparentTemperature: Double?
    var uvIndex: Double?
    var sunrise: Date?
    var sunset: Date?
    var hourlyRain: [RainHour] = []

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale,
                                       timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .gmt))
    }

    /// Follows the in-app language, not the Mac locale, so a German Mac with
    /// the app set to English still shows a decimal point.
    private static func number(_ format: String, _ values: CVarArg...) -> String {
        String(format: format, locale: L10n.locale, arguments: values)
    }

    func upcomingRainPeak(now: Date) -> RainHour? {
        let hours = hourlyRain.filter { $0.end > now && $0.end <= now.addingTimeInterval(6 * 3600) }
        guard hours.count == 6,
              zip(hours, hours.dropFirst()).allSatisfy({ $1.end.timeIntervalSince($0.end) == 3600 }) else { return nil }
        return hours.max { $0.probability < $1.probability }
    }

    var condition: (title: String, glyph: ProviderGlyph) {
        switch code {
        case 0, 1: return (L10n.t("Clear"), isDay ? .weatherSun : .weatherMoon)
        case 2: return (L10n.t("Partly cloudy"), isDay ? .weatherPartlyCloudy : .weatherPartlyCloudyNight)
        case 3: return (L10n.t("Overcast"), .weatherCloud)
        case 45, 48: return (L10n.t("Fog"), .weatherFog)
        case 51, 53, 55, 56, 57: return (L10n.t("Drizzle"), .weatherRain)
        case 61, 63, 65, 66, 67, 80, 81, 82: return (L10n.t("Rain"), .weatherRain)
        case 71, 73, 75, 77, 85, 86: return (L10n.t("Snow"), .weatherSnow)
        case 95, 96, 99: return (L10n.t("Thunderstorm"), .weatherStorm)
        default: return (L10n.t("Unknown conditions"), .weatherCloud)
        }
    }

    func snapshot(location: WeatherLocation, now: Date = Date(), failed: Bool = false) -> ProviderSnapshot {
        let stale = failed || now.timeIntervalSince(measuredAt) > 30 * 60
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let forecastIsToday = forecastDay.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        var windows = [LimitWindow(id: "temperature", label: condition.title,
                                   usedText: Self.number("%.0f°", temperature),
                                   detail: Self.number("%.1f°C", temperature))]
        if let apparentTemperature {
            windows.append(LimitWindow(id: "feels-like", label: L10n.t("Feels like"),
                                       detail: Self.number("%.1f°C", apparentTemperature)))
        }
        if forecastIsToday, let low, let high {
            windows.append(LimitWindow(id: "forecast", label: L10n.t("Daily low / high"),
                                       detail: Self.number("%.0f° / %.0f°C", low, high)))
        }
        if forecastIsToday, let rainChance {
            windows.append(LimitWindow(id: "rain", label: L10n.t("Chance of rain today"),
                                       detail: Self.number("%.0f%%", rainChance)))
        }
        if let humidity, let wind {
            windows.append(LimitWindow(id: "air", label: L10n.t("Humidity / Wind"),
                                       detail: Self.number("%.0f%% · %.1f m/s", humidity, wind)))
        }
        if let rain = upcomingRainPeak(now: now) {
            windows.append(LimitWindow(id: "rain-ahead", label: L10n.t("Precip. peak (next 6h)"),
                                       detail: Self.number("%.0f%%", rain.probability)))
            if rain.probability >= 50 {
                windows.append(LimitWindow(id: "rain-hour", label: L10n.t("Peak hour ending"), detail: clock(rain.end)))
            }
        }
        if forecastIsToday, let sunrise, let sunset, sunrise < sunset,
           calendar.isDate(sunrise, inSameDayAs: now), calendar.isDate(sunset, inSameDayAs: now) {
            windows.append(LimitWindow(id: "sun", label: L10n.t("Sunrise / Sunset"),
                                       detail: "\(clock(sunrise)) / \(clock(sunset))"))
        }
        if forecastIsToday, let uvIndex {
            windows.append(LimitWindow(id: "uv", label: L10n.t("UV peak today"), detail: Self.number("%.1f", uvIndex)))
        }
        windows.append(LimitWindow(id: "measured", label: L10n.t("Updated (city time)"),
                                   detail: clock(measuredAt)))
        return ProviderSnapshot(id: "widget-weather", displayName: location.name, glyph: condition.glyph,
                                fidelity: .official, status: stale ? .stale(since: measuredAt) : .ok,
                                windows: windows, kind: .weather, plan: "Open-Meteo · " + condition.title)
    }
}

enum WeatherClient {
    enum Failure: Error { case invalidLocation, invalidResponse }

    static func search(_ name: String, session: URLSession = .shared) async throws -> [WeatherLocation] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(query.count) else { return [] }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: query),
                          URLQueryItem(name: "count", value: "5"),
                          URLQueryItem(name: "language", value: L10n.locale.language.languageCode?.identifier ?? "en")]
        struct Results: Decodable { let results: [WeatherLocation]? }
        let data = try await request(url.url!, session: session)
        return try JSONDecoder().decode(Results.self, from: data).results?.filter(\.isValid) ?? []
    }

    static func forecastURL(for location: WeatherLocation) throws -> URL {
        guard location.isValid else { throw Failure.invalidLocation }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_min,temperature_2m_max,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "ms")
        ]
        return url.url!
    }

    static func fetch(_ location: WeatherLocation, session: URLSession = .shared) async throws -> WeatherReading {
        try decode(await request(forecastURL(for: location), session: session))
    }

    static func decode(_ data: Data) throws -> WeatherReading {
        struct Response: Decodable {
            struct Current: Decodable {
                let time: Double
                let temperature_2m: Double
                let apparent_temperature: Double?
                let weather_code: Int
                let is_day: Int
                let relative_humidity_2m: Double?
                let wind_speed_10m: Double?
            }
            struct Daily: Decodable {
                let time: [Double]?
                let temperature_2m_min: [Double?]?
                let temperature_2m_max: [Double?]?
                let precipitation_probability_max: [Double?]?
                let sunrise: [Double?]?
                let sunset: [Double?]?
                let uv_index_max: [Double?]?
            }
            struct Hourly: Decodable {
                let time: [Double]?
                let precipitation_probability: [Double?]?
            }
            let current: Current
            let daily: Daily?
            let timezone: String?
            let hourly: Hourly?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let current = result.current
        guard current.time.isFinite, current.time > 0, current.time < 4_102_444_800,
              current.temperature_2m.isFinite, (-100...70).contains(current.temperature_2m),
              (0...1).contains(current.is_day) else { throw Failure.invalidResponse }
        func bounded(_ number: Double?, _ range: ClosedRange<Double>) -> Double? {
            number.flatMap { $0.isFinite && range.contains($0) ? $0 : nil }
        }
        let low = bounded(result.daily?.temperature_2m_min?.first ?? nil, -100...70)
        let high = bounded(result.daily?.temperature_2m_max?.first ?? nil, -100...70)
        let ordered = low.map { low in high.map { low <= $0 } ?? false } ?? false
        var rain: [WeatherReading.RainHour] = []
        if let times = result.hourly?.time, let probabilities = result.hourly?.precipitation_probability,
           times.count == probabilities.count, times.count <= 384,
           zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) {
            rain = zip(times, probabilities).compactMap { time, probability in
                guard let time = bounded(time, 1...4_102_444_799), let probability = bounded(probability, 0...100)
                else { return nil }
                return .init(end: Date(timeIntervalSince1970: time), probability: probability)
            }
        }
        return WeatherReading(measuredAt: Date(timeIntervalSince1970: current.time),
                              temperature: current.temperature_2m, code: current.weather_code,
                              isDay: current.is_day == 1,
                              humidity: bounded(current.relative_humidity_2m, 0...100),
                              wind: bounded(current.wind_speed_10m, 0...150),
                              low: ordered ? low : nil, high: ordered ? high : nil,
                              rainChance: bounded(result.daily?.precipitation_probability_max?.first ?? nil, 0...100),
                              forecastDay: bounded(result.daily?.time?.first, 1...4_102_444_799).map(Date.init(timeIntervalSince1970:)),
                              timeZoneIdentifier: result.timezone ?? "GMT",
                              apparentTemperature: bounded(current.apparent_temperature, -120...80),
                              uvIndex: bounded(result.daily?.uv_index_max?.first ?? nil, 0...40),
                              sunrise: bounded(result.daily?.sunrise?.first ?? nil, 1...4_102_444_799).map(Date.init(timeIntervalSince1970:)),
                              sunset: bounded(result.daily?.sunset?.first ?? nil, 1...4_102_444_799).map(Date.init(timeIntervalSince1970:)),
                              hourlyRain: rain)
    }

    private static func request(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= 1_000_000 else { throw Failure.invalidResponse }
        return data
    }
}
