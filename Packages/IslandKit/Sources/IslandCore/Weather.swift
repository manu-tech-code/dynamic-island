import Foundation

public struct WeatherHour: Equatable, Sendable, Identifiable {
    public var time: Date
    public var temperature: Double
    public var code: Int
    public var isDay: Bool
    public var id: Date { time }
}

public struct WeatherReport: Equatable, Sendable {
    public var temperature: Double
    public var apparentTemperature: Double?
    public var code: Int
    public var isDay: Bool
    public var high: Double?
    public var low: Double?
    public var hours: [WeatherHour]
    public var fetchedAt: Date
    public var place: String?

    public var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

/// WMO weather interpretation codes, as Open-Meteo returns them.
public struct WeatherCondition: Equatable, Sendable {
    public let code: Int
    public let isDay: Bool

    public init(code: Int, isDay: Bool) {
        self.code = code
        self.isDay = isDay
    }

    public var summary: String {
        switch code {
        case 0: isDay ? "Clear" : "Clear night"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "—"
        }
    }

    /// Multicolor SF Symbol for the condition.
    public var symbolName: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 67, 80, 81: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

public enum OpenMeteo {
    /// Forecast URL for rounded coordinates (two decimals, about 1 km).
    public static func forecastURL(latitude: Double, longitude: Double, fahrenheit: Bool) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        return c?.url
    }

    public static func geocodeURL(name: String) -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        c?.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "5")]
        return c?.url
    }

    public struct Place: Equatable, Sendable, Identifiable {
        public var name: String
        public var region: String?
        public var country: String?
        public var latitude: Double
        public var longitude: Double
        public var id: String { "\(latitude),\(longitude)" }
        public var label: String { [name, region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    public static func parsePlaces(_ data: Data) -> [Place] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            return Place(name: name, region: r["admin1"] as? String, country: r["country"] as? String, latitude: lat, longitude: lon)
        }
    }

    /// Parses a forecast; `hours` holds the next `hourCount` hours from `now`.
    public static func parseForecast(_ data: Data, now: Date = Date(), hourCount: Int = 6) -> WeatherReport? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let temp = number(current["temperature_2m"]) else { return nil }
        var hours: [WeatherHour] = []
        if let hourly = obj["hourly"] as? [String: Any],
           let times = hourly["time"] as? [Any], let temps = hourly["temperature_2m"] as? [Any],
           let codes = hourly["weather_code"] as? [Any] {
            let days = hourly["is_day"] as? [Any] ?? []
            for i in times.indices where i < temps.count && i < codes.count {
                guard let t = number(times[i]), let v = number(temps[i]) else { continue }
                let time = Date(timeIntervalSince1970: t)
                guard time > now.addingTimeInterval(-1800) else { continue }
                hours.append(WeatherHour(time: time, temperature: v, code: Int(number(codes[i]) ?? 3),
                                         isDay: (i < days.count ? number(days[i]) : 1) == 1))
                if hours.count == hourCount { break }
            }
        }
        let daily = obj["daily"] as? [String: Any]
        return WeatherReport(
            temperature: temp,
            apparentTemperature: number(current["apparent_temperature"]),
            code: Int(number(current["weather_code"]) ?? 3),
            isDay: number(current["is_day"]) == 1,
            high: (daily?["temperature_2m_max"] as? [Any])?.first.flatMap(number),
            low: (daily?["temperature_2m_min"] as? [Any])?.first.flatMap(number),
            hours: hours, fetchedAt: now, place: nil)
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let d as Double: d
        case let i as Int: Double(i)
        default: nil
        }
    }
}
