import CoreLocation
import Foundation
import MapKit

/// Current conditions and a daily forecast from Open-Meteo (free, no key). Uses your location, or a
/// named place ("weather in London").
@MainActor
enum Weather {
    private static let locator = Locator()

    static func report(place: String?, dayOffset: Int, askingRain: Bool) async -> String {
        var name = place?.capitalized
        var coord: CLLocationCoordinate2D?
        if let place, !place.isEmpty {
            guard let g = await geocode(place) else { return "I couldn't find \(place.capitalized)." }
            coord = g.0; name = g.1
        } else if let here = await locator.current() {
            coord = here.coordinate
            name = await locator.cityName(here)
        } else if let approx = await WebSearch.approximateLocation() {
            coord = CLLocationCoordinate2D(latitude: approx.lat, longitude: approx.lon)
            name = approx.city
        }
        guard let coord else { return "I don't know where you are. Allow Location for Vox in System Settings, or say, weather in Mumbai." }

        let metric = Locale.current.measurementSystem != .us
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: "\(coord.latitude)"), .init(name: "longitude", value: "\(coord.longitude)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "3"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: [Any]] else { return "I couldn't get the weather right now." }
        let unit = metric ? "°C" : "°F"
        let where_ = name.map { " in \($0)" } ?? ""
        func d(_ key: String) -> Double? { (daily[key]?[safe: dayOffset] as? NSNumber)?.doubleValue }
        let hi = d("temperature_2m_max").map { Int($0.rounded()) }, lo = d("temperature_2m_min").map { Int($0.rounded()) }
        let rain = d("precipitation_probability_max").map { Int($0) } ?? 0
        let code = d("weather_code").map { Int($0) } ?? 0

        if askingRain {
            let day = dayOffset == 0 ? "today" : "tomorrow"
            return rain >= 50 ? "Yes, \(rain)% chance of rain\(where_) \(day). Take an umbrella."
                : rain >= 20 ? "Maybe. \(rain)% chance of rain\(where_) \(day)." : "No rain expected\(where_) \(day)."
        }
        if dayOffset == 0, let cur = json["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue {
            let now = describe((cur["weather_code"] as? NSNumber)?.intValue ?? code)
            let feels = (cur["apparent_temperature"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
            var s = "It's \(Int(t.rounded()))\(unit) and \(now)\(where_)."
            if let feels, abs(feels - Int(t.rounded())) >= 3 { s += " Feels like \(feels)°." }
            if let hi, let lo { s += " High \(hi)°, low \(lo)°." }
            if rain >= 30 { s += " \(rain)% chance of rain." }
            return s
        }
        let day = dayOffset == 1 ? "Tomorrow" : "That day"
        return "\(day)\(where_): \(describe(code)), high \(hi ?? 0)\(unit), low \(lo ?? 0)\(unit)\(rain >= 20 ? ", \(rain)% chance of rain" : "")."
    }

    private static func geocode(_ place: String) async -> (CLLocationCoordinate2D, String)? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1")]
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (json["results"] as? [[String: Any]])?.first,
              let lat = (r["latitude"] as? NSNumber)?.doubleValue, let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), r["name"] as? String ?? place.capitalized)
    }

    /// WMO weather codes.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 51...57: return "drizzling"
        case 61...67: return "raining"
        case 71...77: return "snowing"
        case 80...82: return "showery"
        case 85, 86: return "snow showers"
        case 95...99: return "stormy"
        default: return "mixed"
        }
    }
}

/// One-shot location lookup.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async -> CLLocation? {
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 1800 { return l }
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        return await withCheckedContinuation { c in
            waiters.append(c)
            manager.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish(nil) }
        }
    }

    func cityName(_ l: CLLocation) async -> String? {
        try? await MKReverseGeocodingRequest(location: l)?.mapItems.first?.addressRepresentations?.cityName
    }

    private func finish(_ l: CLLocation?) {
        let w = waiters; waiters = []
        w.forEach { $0.resume(returning: l) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.finish(l) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            if !self.waiters.isEmpty, m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways { m.requestLocation() }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
