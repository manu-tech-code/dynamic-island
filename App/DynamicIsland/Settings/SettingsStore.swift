import Foundation
import IslandCore
import Observation

/// Owns the user's settings and saves them as JSON whenever they change.
@Observable
final class SettingsStore {
    var settings: IslandSettings {
        didSet { if settings != oldValue { save() } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            settings = IslandSettings.decode(data)
        } else {
            settings = IslandSettings()
        }
    }

    private func save() {
        defaults.set(settings.normalized().encoded(), forKey: key)
    }

    func resetToDefaults() {
        settings = IslandSettings()
    }
}
