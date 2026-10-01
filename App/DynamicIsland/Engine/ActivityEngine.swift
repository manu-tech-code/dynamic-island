import Foundation
import IslandCore
import Observation

/// A module that publishes live activities.
protocol ActivityProvider: AnyObject {
    var kind: ActivityKind { get }
    var activities: [Activity] { get }
}

/// Collects activities from every enabled module, ranks them with the user's
/// priority and limit, and runs the alert queue (one alert at a time).
@Observable
final class ActivityEngine {
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private var providers: [ActivityProvider] = []

    private(set) var alert: IslandAlert?
    @ObservationIgnored private var queue: [IslandAlert] = []
    @ObservationIgnored private var alertTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func register(_ provider: ActivityProvider) {
        providers.append(provider)
    }

    /// Every live activity from enabled modules, in no particular order.
    var live: [Activity] {
        let s = settings.settings
        return providers.filter { s[module: $0.kind].enabled }.flatMap(\.activities)
    }

    /// What the compact island shows.
    var ranked: RankedActivities {
        let s = settings.settings
        return ActivityRanking.rank(live, order: s.priority, compactKinds: s.compactKinds, limit: s.activityLimit)
    }

    func activity(id: String) -> Activity? {
        live.first { $0.id == id }
    }

    // MARK: alerts

    func post(_ alert: IslandAlert) {
        switch alert.style {
        case .message, .updateAvailable: break // not tied to a module
        default: guard settings.settings[module: alert.kind].enabled else { return }
        }
        Log.info("alert \(alert.style)")
        queue.append(alert)
        if self.alert == nil { showNext() }
    }

    /// Shows or updates a HUD (volume, brightness). While a key is held the
    /// HUD updates in place and its hold restarts; it never queues.
    func showHUD(_ hud: IslandAlert) {
        guard settings.settings[module: .hud].enabled else { return }
        if let current = alert, current.isHUD {
            alert = IslandAlert(id: current.id, kind: hud.kind, style: hud.style, holdSeconds: hud.holdSeconds)
        } else if alert == nil {
            alert = hud
        } else {
            return // a real alert is showing; it wins
        }
        alertTask?.cancel()
        let hold = hud.holdSeconds
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.alert = nil
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.showNext()
        }
    }

    func dismissAlert() {
        alertTask?.cancel()
        alert = nil
        showNext()
    }

    private func showNext() {
        guard !queue.isEmpty else { alert = nil; return }
        let next = queue.removeFirst()
        alert = next
        alertTask?.cancel()
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.holdSeconds))
            guard !Task.isCancelled else { return }
            self?.alert = nil
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.showNext()
        }
    }
}
