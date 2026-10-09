import AppKit
import CoreBluetooth
import EventKit
import IslandCore
import Observation

/// Owns the user's settings and saves them as JSON whenever they change.
@Observable
final class SettingsStore {
    var settings: IslandSettings {
        didSet { if settings != oldValue { save() } }
    }

    /// Nothing was saved before this launch: a new install, which starts from
    /// defaults fitted to this Mac and gets the first-run window. Settings saved
    /// by any earlier version never count as new.
    @ObservationIgnored let isNewInstall: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "settings.v1"
    /// Set at the first launch of every version since 0.3 (the island's one-time tip).
    static let launchedBeforeKey = "didShowWelcome"

    init(defaults: UserDefaults = .standard, mac: @autoclosure () -> MacTraits = .current) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            settings = IslandSettings.decode(data)
            isNewInstall = false
        } else if defaults.bool(forKey: Self.launchedBeforeKey) {
            // An earlier version ran, but nothing was changed, so nothing was saved:
            // its defaults stay, saved now so newer defaults never replace them.
            settings = IslandSettings.earlierDefaults
            isNewInstall = false
            save()
        } else {
            settings = IslandSettings.newInstall(on: mac())
            isNewInstall = true
        }
    }

    private func save() {
        defaults.set(settings.normalized().encoded(), forKey: key)
    }

    /// Saves now, changed or not, so the next launch isn't a new install.
    func saveNow() { save() }

    /// Back to what a new install on this Mac starts with.
    func resetToDefaults() {
        settings = IslandSettings.newInstall(on: .current)
    }
}

extension MacTraits {
    /// This Mac as it is now: a notch on any display (the island goes there),
    /// a battery, and the permissions macOS has already given.
    static var current: MacTraits {
        var allowed: Set<ActivityKind> = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { allowed.insert(.calendar) }
        if CBManager.authorization == .allowedAlways { allowed.insert(.devices) }
        return MacTraits(hasNotch: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 },
                         hasBattery: BatteryService.read().hasBattery, allowed: allowed)
    }
}
