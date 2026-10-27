import Foundation
import Observation

/// Current conditions and forecast from Open-Meteo (free, no key). Values arrive in the
/// configured units, so they are displayed as-is.
@MainActor
@Observable
final class WeatherStore {
    struct Now {
        let temperature: Double
        let feelsLike: Double
        let code: Int
        let isDay: Bool
        let wind: Double
    }

    struct Hour: Identifiable {
        var id: Date { time }
        let time: Date
        let temperature: Double
        let precipitation: Int
        let code: Int
    }

    struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let high: Double
        let low: Double
        let precipitation: Int
        let code: Int
        let sunrise: Date
        let sunset: Date
    }

    private(set) var now: Now?
    private(set) var hours: [Hour] = []
    private(set) var days: [Day] = []
    private(set) var problem: String?
    private(set) var lastUpdated: Date?

    let config: HomeConfig

    init(config: HomeConfig = .load()) {
        self.config = config
    }

    var unitSymbol: String { config.isCelsius ? "C" : "F" }

    func start() async {
        if Launch.isDemo {
            loadDemo()
            return
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(problem == nil ? 15 * 60 : 60))
        }
    }

    func refresh() async {
        guard !Launch.isDemo else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: "\(config.location.latitude)"),
            .init(name: "longitude", value: "\(config.location.longitude)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            .init(name: "temperature_unit", value: config.isCelsius ? "celsius" : "fahrenheit"),
            .init(name: "wind_speed_unit", value: config.isCelsius ? "kmh" : "mph"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            apply(try decoder.decode(Forecast.self, from: data))
            problem = nil
            lastUpdated = .now
        } catch {
            problem = "Weather: \(error.localizedDescription)"
        }
    }

    /// Hours from the current one onward.
    func upcomingHours(_ count: Int, from date: Date = .now) -> [Hour] {
        let start = date.addingTimeInterval(-3600)
        return Array(hours.filter { $0.time > start }.prefix(count))
    }

    // MARK: - Open-Meteo

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let weatherCode: Int
            let windSpeed10m: Double
            let isDay: Int
        }
        struct Hourly: Decodable {
            let time: [TimeInterval]
            let temperature2m: [Double?]
            let precipitationProbability: [Int?]
            let weatherCode: [Int?]
        }
        struct Daily: Decodable {
            let time: [TimeInterval]
            let weatherCode: [Int?]
            let temperature2mMax: [Double?]
            let temperature2mMin: [Double?]
            let precipitationProbabilityMax: [Int?]
            let sunrise: [TimeInterval]
            let sunset: [TimeInterval]
        }
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    private func apply(_ f: Forecast) {
        now = Now(temperature: f.current.temperature2m, feelsLike: f.current.apparentTemperature,
                  code: f.current.weatherCode, isDay: f.current.isDay == 1, wind: f.current.windSpeed10m)
        hours = f.hourly.time.indices.compactMap { i in
            guard let t = f.hourly.temperature2m[i] else { return nil }
            return Hour(time: Date(timeIntervalSince1970: f.hourly.time[i]), temperature: t,
                        precipitation: f.hourly.precipitationProbability[i] ?? 0, code: f.hourly.weatherCode[i] ?? 0)
        }
        days = f.daily.time.indices.compactMap { i in
            guard let high = f.daily.temperature2mMax[i], let low = f.daily.temperature2mMin[i] else { return nil }
            return Day(date: Date(timeIntervalSince1970: f.daily.time[i]), high: high, low: low,
                       precipitation: f.daily.precipitationProbabilityMax[i] ?? 0, code: f.daily.weatherCode[i] ?? 0,
                       sunrise: Date(timeIntervalSince1970: f.daily.sunrise[i]),
                       sunset: Date(timeIntervalSince1970: f.daily.sunset[i]))
        }
    }

    // MARK: - Demo

    private func loadDemo() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // Mild day, coolest at 6 am and warmest at 3 pm, with rain around school pickup.
        let rain: [Int: Int] = [12: 20, 13: 45, 14: 70, 15: 65, 16: 40, 17: 20]
        hours = (0..<48).map { i in
            let hourOfDay = i % 24
            let temperature = 57 - 9 * cos(Double(hourOfDay - 3) / 24 * 2 * .pi)
            let precipitation = i < 24 ? rain[hourOfDay] ?? 0 : 10
            return Hour(time: today.addingTimeInterval(Double(i) * 3600), temperature: temperature.rounded(),
                        precipitation: precipitation, code: precipitation >= 60 ? 61 : precipitation >= 20 ? 3 : 2)
        }
        let highs: [Double] = [66, 61, 58, 63, 68, 71, 69], lows: [Double] = [49, 47, 44, 46, 50, 53, 52]
        let codes = [61, 63, 3, 2, 1, 0, 2], precip = [70, 80, 25, 10, 0, 0, 10]
        days = (0..<7).map { i in
            let date = calendar.date(byAdding: .day, value: i, to: today) ?? today
            return Day(date: date, high: highs[i], low: lows[i], precipitation: precip[i], code: codes[i],
                       sunrise: date.addingTimeInterval(7 * 3600 + 21 * 60), sunset: date.addingTimeInterval(18 * 3600 + 14 * 60))
        }
        now = Now(temperature: 54, feelsLike: 51, code: 2, isDay: true, wind: 8)
        lastUpdated = .now
    }
}

/// WMO weather codes (as used by Open-Meteo) → SF Symbol and words.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorms"
        case 96, 99: "Thunderstorms with hail"
        default: "—"
        }
    }
}
