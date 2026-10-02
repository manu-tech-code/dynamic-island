import AppKit
import ApplicationServices
import IslandCore
import Observation

/// Messages from any app on the island (Settings › Messages): reads macOS's
/// notification banners as they appear (`NotificationBannerReader`) and shows
/// them in the chosen style. In the badges style, each app's unread count
/// stays on the island until that app is opened. Nothing is kept beyond that.
@Observable
final class MessageAlertsService: ActivityProvider {
    let kind: ActivityKind = .messages
    /// Unread messages per app, newest app first (the badges style).
    private(set) var unread: [UnreadApp] = []
    /// Accessibility, which reading the banners needs.
    private(set) var trusted = AXIsProcessTrusted()

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let reader = NotificationBannerReader()
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var trustPoll: Task<Void, Never>?

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        engine.register(self)
        reader.onBanner = { [weak self] banner in self?.received(banner) }
        // macOS's own banner stays out of sight for the apps the island shows ("" asks: for any app?).
        reader.hidesBanner = { [settings] app in
            let s = settings.settings
            guard s[module: .messages].enabled, s.messages.hideSystemBanner else { return false }
            return app.isEmpty || s.messages.shows(app: app)
        }
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
        if !enabled { unread = [] }
        if enabled, !trusted { waitForTrust() }
    }

    /// Asks for Accessibility (the same permission the HUD uses).
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        waitForTrust()
    }

    private func waitForTrust() {
        guard trustPoll == nil, !trusted else { return }
        trustPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
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
        let app = Self.runningApp(named: banner.appName)
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let bundleID = app?.bundleIdentifier ?? Self.installedApp(named: banner.appName)?.bundleID
        // Each app the first time: it joins the list in Settings, on or off by default.
        if s.messages.apps[banner.appName] == nil {
            settings.settings.messages.apps[banner.appName] = MessageAlertSettings.shownByDefault(app: banner.appName)
        }
        guard s.messages.shows(app: banner.appName) else { return }
        // Nothing to show: a banner that's only an app name.
        guard !banner.title.isEmpty || !banner.body.isEmpty else { return }
        let message = MessageInfo(id: banner.id, app: banner.appName, bundleID: bundleID,
                                  sender: banner.title.isEmpty ? banner.appName : banner.title,
                                  context: banner.subtitle, text: banner.body)
        show(message, style: s.messages.style)
    }

    /// Shows a message as if it had arrived (Settings' test button, debugging).
    func show(_ message: MessageInfo, style: MessageAlertStyle? = nil) {
        let s = settings.settings
        let style = style ?? s.messages.style
        // The ticker stays until the message has scrolled by.
        let hold = style == .ticker ? max(s.messages.holdSeconds, 3 + Double(message.text.count) * 0.09) : s.messages.holdSeconds
        if style == .badges { count(message) }
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
        } else if let url = bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) ?? Self.installedApp(named: name)?.url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        clear(name: name, bundleID: bundleID)
    }

    func clearAll() { unread = [] }

    #if DEBUG
    @ObservationIgnored var lastMessage: MessageInfo?
    #endif

    private func clear(name: String?, bundleID: String?) {
        guard !unread.isEmpty else { return }
        unread.removeAll { u in (bundleID != nil && u.bundleID == bundleID) || u.app == name }
    }

    // MARK: apps

    /// The apps Settings lists: every app that has sent a banner, and the
    /// messaging and music apps installed here (so WhatsApp and Music are there
    /// before they've said anything).
    func appList() -> [String] {
        let installed = MessagingApps.bundleIDs.union(MessagingApps.mediaBundleIDs).compactMap { id -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let seen = Set(settings.settings.messages.apps.keys)
        // Banners use the short name ("Teams"), the app file the long one
        // ("Microsoft Teams"): list it once, as its banners name it.
        let extra = installed.map(Self.clean).filter { name in
            !seen.contains { $0 == name || name.hasSuffix(" " + $0) || $0.hasSuffix(" " + name) }
        }
        return seen.union(extra).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The app's icon, for the island.
    func icon(for app: String, bundleID: String?) -> NSImage? {
        if let cached = icons[app] { return cached }
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? Self.runningApp(named: app)?.bundleURL ?? Self.installedApp(named: app)?.url
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[app] = icon
        return icon
    }

    /// Without the invisible marks some apps put in their names (WhatsApp's starts with one).
    private static func clean(_ name: String) -> String {
        name.unicodeScalars.filter { !["\u{200E}", "\u{200F}", "\u{202A}", "\u{202C}"].contains($0) }
            .map(String.init).joined().trimmingCharacters(in: .whitespaces)
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name && $0.activationPolicy == .regular }
            ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
    }

    /// An app that isn't running, found by its name where apps live.
    private static func installedApp(named name: String) -> (url: URL, bundleID: String?)? {
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return (url, Bundle(url: url)?.bundleIdentifier) }
        }
        return nil
    }
}
