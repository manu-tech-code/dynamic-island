import AppKit
import IslandCore
import Observation

/// Regular apps that are running but not in front, most recently used first.
@Observable
final class BackgroundAppsService: ActivityProvider {
    let kind = ActivityKind.backgroundApps
    private(set) var apps: [RunningAppInfo] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// pid → last time it was frontmost.
    @ObservationIgnored private var lastActive: [pid_t: Date] = [:]
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var activities: [Activity] {
        let excluded = Set(settings.settings.backgroundApps.excludedBundleIDs)
        let visible = apps.filter { !excluded.contains($0.bundleID ?? "") }
        guard !visible.isEmpty else { return [] }
        return [Activity(id: "backgroundApps", kind: .backgroundApps, payload: .backgroundApps(visible),
                         relevance: 0, startedAt: .distantPast)]
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let isActivation = note.name == NSWorkspace.didActivateApplicationNotification
                MainActor.assumeIsolated {
                    if isActivation, let pid { self?.lastActive[pid] = Date() }
                    self?.rebuild()
                }
            })
        }
        rebuild()
    }

    func icon(for app: RunningAppInfo) -> NSImage {
        if let cached = icons[app.pid] { return cached }
        let image = NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[app.pid] = image
        return image
    }

    /// Brings the app to the front. Uses LaunchServices, which works from an
    /// app that isn't active itself.
    func activate(_ app: RunningAppInfo) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if let url = running.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            running.activate()
        }
    }

    private func rebuild() {
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me && $0.processIdentifier != front
        }
        let alive = Set(running.map(\.processIdentifier))
        lastActive = lastActive.filter { alive.contains($0.key) }
        icons = icons.filter { alive.contains($0.key) }
        let sorted = running.sorted { a, b in
            let da = lastActive[a.processIdentifier] ?? a.launchDate ?? .distantPast
            let db = lastActive[b.processIdentifier] ?? b.launchDate ?? .distantPast
            return da > db
        }
        let next = sorted.map { RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "App") }
        if next != apps { apps = next }
    }
}
