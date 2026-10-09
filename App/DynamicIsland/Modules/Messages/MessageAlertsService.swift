import AppKit
import ApplicationServices
import IslandCore
import Observation

/// Messages from any app on the island (Settings › Messages): reads macOS's
/// notification banners as they appear (`NotificationBannerReader`) and shows
/// them in the chosen style. In the badges style, each app's unread count
/// stays on the island until that app is opened, and the recent ones stay in a
/// list on the island until the app quits. Nothing is saved.
@Observable
final class MessageAlertsService: ActivityProvider {
    let kind: ActivityKind = .messages
    /// Unread messages per app, newest app first (the badges style).
    private(set) var unread: [UnreadApp] = []
    /// The messages that reached the island lately, newest first (the dashboard's list).
    private(set) var recent = RecentMessages()
    /// Accessibility, which reading the banners needs.
    private(set) var trusted = AXIsProcessTrusted()

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let reader = NotificationBannerReader()
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var trustPoll: Task<Void, Never>?
    /// The displays the island is on (set by the islands).
    @ObservationIgnored var islandDisplays: () -> Set<CGDirectDisplayID> = { [] }
    @ObservationIgnored private var installed = InstalledApps.Catalog()
    @ObservationIgnored private var installedTask: Task<Void, Never>?
    @ObservationIgnored private var runningNames: (date: Date, names: [String])?
    @ObservationIgnored private var cachedAppList: (date: Date, list: [String])?

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        engine.register(self)
        // Left out of sight by a crash last time? Back on screen first.
        NotificationBannerReader.recoverIfNeeded()
        reader.restoreOnSignals()
        reader.onBanner = { [weak self] banner in self?.received(banner) }
        // macOS's own banner stays out of sight for the apps the island shows.
        reader.hidesAny = { [settings] in
            let s = settings.settings
            return s[module: .messages].enabled && s.messages.hideSystemBanner
        }
        reader.hidesBanner = { [weak self] app in
            guard let self, self.reader.hidesAny(), !app.isEmpty else { return false }
            return self.settings.settings.messages.shows(app: app, bundleID: self.bundleID(for: app))
        }
        reader.islandAt = { [weak self] point in self?.islandShows(at: point) ?? true }
        reader.appNames = { [weak self] in self?.appNames() ?? [] }
        reader.onTrustLost = { [weak self] in
            self?.trusted = false
            self?.waitForTrust()
        }
        refreshInstalled()
        // Opening an app reads its messages: its badge goes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.clear(name: app.localizedName, bundleID: app.bundleIdentifier) } }
        }
    }

    var activities: [Activity] {
        guard !unread.isEmpty, settings.settings.messages.style == .badges else { return [] }
        return [Activity(id: "messages", kind: .messages, payload: .messages(unread), relevance: 0.6)]
    }

    func start() {
        whenChanged({ [settings] in settings.settings[module: .messages].enabled }) { [weak self] on in self?.update(on) }
        // The list's length follows Settings; turned off, it's emptied.
        whenChanged({ [settings] in "\(settings.settings.messages.keepRecent) \(settings.settings.messages.recentLimit)" }) { [weak self] _ in
            guard let self else { return }
            let s = self.settings.settings.messages
            if s.keepRecent { self.recent.setLimit(s.recentLimit) } else { self.recent.removeAll() }
        }
        // Hiding turned on or off, or an app switched: macOS's banner window follows.
        whenChanged({ [settings] in "\(settings.settings.messages.hideSystemBanner) \(settings.settings.messages.apps.sorted { $0.key < $1.key })" }) { [weak self] _ in
            self?.reader.refresh()
        }
        update(settings.settings[module: .messages].enabled)
    }

    /// Quitting: macOS's banners go back on screen.
    func stop() { reader.stop() }

    private func update(_ enabled: Bool) {
        trusted = AXIsProcessTrusted()
        if enabled, trusted { reader.start() } else { reader.stop() }
        if !enabled { unread = []; recent.removeAll() }
        if enabled, !trusted { waitForTrust() }
    }

    /// Asks for Accessibility (the same permission the HUD uses).
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        waitForTrust()
    }

    /// Every 2 s for two minutes after asking, then every 15 s.
    private func waitForTrust() {
        guard trustPoll == nil, !trusted else { return }
        trustPoll = Task { [weak self] in
            let started = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Date.now.timeIntervalSince(started) < 120 ? 2 : 15))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.trustPoll = nil
                    self.update(self.settings.settings[module: .messages].enabled)
                    return
                }
            }
        }
    }

    // MARK: a banner arrived

    private func received(_ banner: NotificationBannerReader.Banner) {
        let s = settings.settings
        guard s[module: .messages].enabled else { return }
        // A banner whose app can't be told still shows, but isn't remembered in Settings.
        let name = banner.appName ?? String(localized: "Notification")
        let app = banner.appName.flatMap(Self.runningApp(named:))
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let bundleID = app?.bundleIdentifier ?? banner.appName.flatMap { installed.app(named: $0)?.bundleID }
        if let known = banner.appName {
            // Each app the first time: it joins the list in Settings, on or off by default.
            if s.messages.apps[known] == nil {
                settings.settings.messages.apps[known] = MessageAlertSettings.shownByDefault(app: known, bundleID: bundleID)
                cachedAppList = nil
            }
            guard settings.settings.messages.shows(app: known, bundleID: bundleID) else { return }
        }
        // Nothing to show: a banner that's only an app name.
        guard !banner.title.isEmpty || !banner.body.isEmpty else { return }
        let message = MessageInfo(id: banner.id, app: name, bundleID: bundleID,
                                  sender: banner.title.isEmpty ? name : banner.title,
                                  context: banner.subtitle, text: banner.body)
        show(message, style: s.messages.style)
    }

    // MARK: which app, which display

    /// The names of the apps here, as macOS shows them (in the user's language),
    /// for telling which app a banner is from.
    private func appNames() -> [String] {
        if let cached = runningNames, Date.now.timeIntervalSince(cached.date) < 5 { return cached.names }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let names = Array(Set(running.map(MessageInfo.clean) + installed.names))
        runningNames = (.now, names)
        return names
    }

    private func bundleID(for app: String) -> String? {
        Self.runningApp(named: app)?.bundleIdentifier ?? installed.app(named: app)?.bundleID
    }

    /// Whether the island is on the display at this point (Accessibility's
    /// coordinates, from the top of the main display).
    private func islandShows(at point: CGPoint) -> Bool {
        let displays = islandDisplays()
        guard !displays.isEmpty, let main = NSScreen.screens.first else { return true }
        let spot = CGPoint(x: point.x + 1, y: main.frame.maxY - point.y - 1)
        let screen = NSScreen.screens.first { $0.frame.contains(spot) } ?? main
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return true }
        return displays.contains(id)
    }

    /// The apps in the usual folders, read in the background now and then.
    private func refreshInstalled() {
        guard installedTask == nil else { return }
        installedTask = Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) { InstalledApps.scan() }.value
            guard let self else { return }
            self.installed = catalog
            self.runningNames = nil
            self.cachedAppList = nil
            self.installedTask = nil
        }
    }

    /// Shows a message as if it had arrived (Settings' test button, debugging).
    func show(_ message: MessageInfo, style: MessageAlertStyle? = nil) {
        let s = settings.settings
        let style = style ?? s.messages.style
        // The ticker stays until the message has scrolled by.
        let hold = style == .ticker ? max(s.messages.holdSeconds, 3 + Double(message.text.count) * 0.09) : s.messages.holdSeconds
        if style == .badges { count(message) }
        if s.messages.keepRecent {
            recent.setLimit(s.messages.recentLimit)
            recent.add(message)
        }
        #if DEBUG
        lastMessage = message
        #endif
        Log.info("messages: \(message.app) (\(style.rawValue))")
        engine.showMessage(message, style: style, hold: hold)
    }

    private func count(_ message: MessageInfo) {
        var list = unread
        if let i = list.firstIndex(where: { $0.app == message.app }) {
            var app = list.remove(at: i)
            app.count += 1
            app.lastSender = message.sender
            list.insert(app, at: 0)
        } else {
            list.insert(UnreadApp(app: message.app, bundleID: message.bundleID, count: 1, lastSender: message.sender), at: 0)
        }
        unread = list
    }

    // MARK: opening

    /// Opens the message's conversation, as clicking macOS's notification would:
    /// its banner while it's up (even out of sight), or else its entry in
    /// Notification Center. Only if neither is there, the app.
    func open(_ message: MessageInfo) {
        clear(name: message.app, bundleID: message.bundleID)
        recent.markRead(id: message.id)
        Task {
            if await reader.open(id: message.id) {
                Log.info("messages: opened the conversation")
            } else {
                openApp(name: message.app, bundleID: message.bundleID)
            }
        }
    }

    func openApp(name: String, bundleID: String?) {
        if let app = Self.runningApp(named: name) {
            app.activate()
        } else if let url = bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) ?? installed.app(named: name)?.url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        clear(name: name, bundleID: bundleID)
    }

    func clearAll() { unread = [] }

    // MARK: recent messages

    func markAllRecentRead() { recent.markAllRead() }
    func removeRecent(_ id: String) { recent.remove(id: id) }
    func clearRecent() { recent.removeAll() }

    #if DEBUG
    @ObservationIgnored var lastMessage: MessageInfo?

    /// Sample messages for renders: five, over the last day, the older ones read.
    func debugFillRecent() {
        let now = Date.now
        let samples = [
            MessageInfo(id: "debug-5", app: "Mail", bundleID: "com.apple.mail", sender: "GitHub", context: "Release v0.11.1",
                        text: "manu-tech-code published a release", date: now.addingTimeInterval(-26 * 3600)),
            MessageInfo(id: "debug-4", app: "Messages", bundleID: "com.apple.MobileSMS", sender: "Mum", text: "Call me when you're free ❤️",
                        date: now.addingTimeInterval(-3 * 3600)),
            MessageInfo(id: "debug-3", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", sender: "Kofi", context: "#design",
                        text: "Pushed the new icons, can you take a look before standup? The tray one is still a bit heavy.", date: now.addingTimeInterval(-42 * 60)),
            MessageInfo(id: "debug-2", app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", sender: "Ama Mensah", text: "Are we still on for 6? I'll bring the charger 🔌",
                        date: now.addingTimeInterval(-6 * 60)),
            MessageInfo(id: "debug-1", app: "Microsoft Teams", bundleID: "com.microsoft.teams2", sender: "Sarah Owusu", context: "Daily sync",
                        text: "Running 5 minutes late", date: now.addingTimeInterval(-20)),
        ]
        recent.setLimit(settings.settings.messages.recentLimit)
        for m in samples { recent.add(m) }
        recent.markRead(id: "debug-5")
        recent.markRead(id: "debug-4")
    }
    #endif

    private func clear(name: String?, bundleID: String?) {
        if recent.entries.contains(where: { !$0.read }) { recent.markRead(app: name, bundleID: bundleID) }
        guard !unread.isEmpty else { return }
        unread.removeAll { u in (bundleID != nil && u.bundleID == bundleID) || u.app == name }
    }

    // MARK: apps

    /// The apps Settings lists: every app that has sent a banner, and the
    /// messaging and music apps installed here (so WhatsApp and Music are there
    /// before they've said anything). Kept a minute: Settings asks often.
    func appList() -> [String] {
        if let cached = cachedAppList, Date.now.timeIntervalSince(cached.date) < 60 { return cached.list }
        let ids = MessagingApps.bundleIDs.union(MessagingApps.mediaBundleIDs)
        let installedNames = installed.apps.filter { $0.bundleID.map(ids.contains) ?? false }.map(\.name)
        let seen = Set(settings.settings.messages.apps.keys)
        // Banners use the short name ("Teams"), the app file the long one
        // ("Microsoft Teams"): list it once, as its banners name it.
        let extra = installedNames.filter { name in
            !seen.contains { $0 == name || name.hasSuffix(" " + $0) || $0.hasSuffix(" " + name) }
        }
        let list = seen.union(extra).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cachedAppList = (.now, list)
        return list
    }

    /// The app's icon, for the island.
    func icon(for app: String, bundleID: String?) -> NSImage? {
        if let cached = icons[app] { return cached }
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? Self.runningApp(named: app)?.bundleURL ?? installed.app(named: app)?.url
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[app] = icon
        return icon
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName.map(MessageInfo.clean) == name }
        return apps.first { $0.activationPolicy == .regular } ?? apps.first
    }
}

/// The apps in the usual folders, by the name macOS shows for each (in the
/// user's language: Messages.app is "Nachrichten" in German) and by file name.
nonisolated enum InstalledApps {
    struct App: Sendable {
        let name: String
        let url: URL
        let bundleID: String?
    }

    struct Catalog: Sendable {
        var apps: [App] = []
        private var byName: [String: App] = [:]

        init(apps: [App] = []) {
            self.apps = apps
            for app in apps {
                byName[app.name] = byName[app.name] ?? app
                let file = MessageInfo.clean(app.url.deletingPathExtension().lastPathComponent)
                byName[file] = byName[file] ?? app
            }
        }

        var names: [String] { apps.map(\.name) }
        func app(named name: String) -> App? { byName[name] }
    }

    static func scan() -> Catalog {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        var apps: [App] = []
        func add(_ path: String) {
            let url = URL(fileURLWithPath: path)
            let name = MessageInfo.clean(fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
            apps.append(App(name: name, url: url, bundleID: Bundle(url: url)?.bundleIdentifier))
        }
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !item.hasPrefix(".") {
                let path = folder + "/" + item
                if item.hasSuffix(".app") {
                    add(path)
                } else {
                    // One folder down: "Microsoft Office/…", "Adobe …/…".
                    for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") { add(path + "/" + inner) }
                }
            }
        }
        return Catalog(apps: apps)
    }
}
