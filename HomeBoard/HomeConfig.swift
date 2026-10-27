import Foundation

/// Settings for the home side of the board, read from HomeConfig.json (gitignored, holds the
/// API key). The school feeds stay in SchoolBoard's BoardConfig.json.
struct HomeConfig: Codable, Sendable {
    struct Location: Codable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    var location: Location
    /// "fahrenheit" (default) or "celsius".
    var units: String?
    /// HomeKit home to show; the first home when nil.
    var homeName: String?
    /// Accessory names to leave off the board.
    var hiddenAccessories: [String]?
    var anthropicAPIKey: String?
    var model: String?
    var effort: String?
    var briefingMinutes: Double?

    var isCelsius: Bool { units == "celsius" }
    var hasAPIKey: Bool { anthropicAPIKey?.hasPrefix("sk-ant-") == true }

    static func load() -> HomeConfig {
        for name in ["HomeConfig", "HomeConfig.example"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let config = try? JSONDecoder().decode(HomeConfig.self, from: data) {
                return config
            }
        }
        return HomeConfig(location: .init(name: "Home", latitude: 37.3349, longitude: -122.0090))
    }
}

enum Launch {
    /// `-demo` shows sample home, weather and briefing data (and SchoolBoard's demo week).
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
}

/// Formats a temperature given in °C for the configured units.
func degrees(_ celsius: Double, _ config: HomeConfig) -> String {
    let value = config.isCelsius ? celsius : celsius * 9 / 5 + 32
    return "\(Int(value.rounded()))°"
}
