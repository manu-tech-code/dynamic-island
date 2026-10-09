import CoreLocation
import IslandCore
import MapKit
import Observation

/// Weather from Open-Meteo (free, no key). Location comes from Location
/// Services, or a place the user picks in Settings. Coordinates are rounded
/// to about 1 km before they leave the Mac. Refreshes every 30 minutes, and
/// only while a weather widget is on the dashboard.
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    enum State: Equatable { case idle, locating, loading, ready, needsLocation, failed(String) }

    private(set) var report: WeatherReport?
    private(set) var state: State = .idle
    private(set) var placeName: String?
    private(set) var authorization: CLAuthorizationStatus

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastLocation: CLLocation?

    init(settings: SettingsStore) {
        self.settings = settings
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Automatic follows System Settings › General › Language & Region ›
    /// Temperature, which can differ from the region's measurement system.
    var usesFahrenheit: Bool {
        switch settings.settings.weather.unit {
        case .celsius: false
        case .fahrenheit: true
        case .automatic: UnitTemperature(forLocale: .current) == .fahrenheit
        }
    }

    /// Starts the refresh loop if a weather widget is on the dashboard.
    func updateDemand() {
        let wanted = settings.settings.dashboard.contains { $0.kind == .weather }
        if wanted, loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(30 * 60))
                }
            }
        } else if !wanted {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() {
        let w = settings.settings.weather
        if w.useCurrentLocation {
            switch manager.authorizationStatus {
            case .notDetermined:
                state = .locating
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorized:
                state = .locating
                manager.requestLocation()
            default:
                if let lat = w.latitude, let lon = w.longitude { fetch(lat, lon, place: w.placeName) } else { state = .needsLocation }
            }
        } else if let lat = w.latitude, let lon = w.longitude {
            fetch(lat, lon, place: w.placeName)
        } else {
            state = .needsLocation
        }
    }

    func search(_ query: String) async -> [OpenMeteo.Place] {
        guard let url = OpenMeteo.geocodeURL(name: query),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return OpenMeteo.parsePlaces(data)
    }

    func choose(_ place: OpenMeteo.Place) {
        settings.settings.weather.placeName = place.name
        settings.settings.weather.latitude = place.latitude
        settings.settings.weather.longitude = place.longitude
        settings.settings.weather.useCurrentLocation = false
        refresh()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedAlways || status == .authorized { self.manager.requestLocation() }
            else if status == .denied || status == .restricted { self.refresh() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let box = SendableBox(loc)
        Task { @MainActor in self.located(box.value) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            Log.error("weather location failed: \(message)")
            if let last = self.lastLocation { self.located(last) } else { self.refreshFromSaved() }
        }
    }

    private func refreshFromSaved() {
        let w = settings.settings.weather
        if let lat = w.latitude, let lon = w.longitude { fetch(lat, lon, place: w.placeName) } else { state = .needsLocation }
    }

    private func located(_ loc: CLLocation) {
        lastLocation = loc
        fetch(loc.coordinate.latitude, loc.coordinate.longitude, place: nil)
        Task {
            if let request = MKReverseGeocodingRequest(location: loc),
               let items = try? await request.mapItems, let city = items.first?.addressRepresentations?.cityName {
                placeName = city
                report?.place = city
            }
        }
    }

    // MARK: fetching

    private func fetch(_ lat: Double, _ lon: Double, place: String?) {
        guard let url = OpenMeteo.forecastURL(latitude: lat, longitude: lon, fahrenheit: usesFahrenheit) else { return }
        if report == nil { state = .loading }
        if let place { placeName = place }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard var r = OpenMeteo.parseForecast(data) else { state = .failed("Unexpected weather data"); return }
                r.place = placeName
                report = r
                state = .ready
                Log.info("weather: \(Int(r.temperature))° \(r.condition.summary) \(placeName ?? "")")
            } catch {
                state = .failed("Couldn't reach Open-Meteo")
            }
        }
    }
}
