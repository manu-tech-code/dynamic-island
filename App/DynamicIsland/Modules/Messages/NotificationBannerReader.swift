import AppKit
import ApplicationServices
import IslandCore

/// Reads macOS's notification banners as they appear. Every app's banners are
/// drawn by one system process (Notification Center), each as an element with
/// the app, a title, a subtitle and a body, and an action that opens it.
/// Accessibility lets us read them, with the permission the HUD already uses.
/// It sees only what macOS shows: each app's notification settings and Focus apply.
///
/// To show a message only on the island, the window macOS draws its banners in
/// is moved above the screen, not closed: closing a banner (its ✕) clears it
/// from Notification Center, while a banner out of sight times out into the
/// list as usual and can still be pressed to open its conversation. macOS makes
/// a new window for each run of banners, and puts it back when its panel opens.
final class NotificationBannerReader {
    struct Banner {
        /// Notification Center's id for the notification: the same on the banner
        /// and later in Notification Center's list.
        let id: String
        let appName: String
        let title: String
        let subtitle: String
        let body: String
        /// The banner itself, to open it.
        let element: AXUIElement
    }

    static let bundleID = "com.apple.notificationcenterui"
    /// Banners still up after this long are alerts that wait for an answer:
    /// they come back on screen so they can get one.
    static let persistentAfter: TimeInterval = 7

    var onBanner: (Banner) -> Void = { _ in }
    /// Whether macOS's own banner for this app should stay out of sight.
    var hidesBanner: (String) -> Bool = { _ in false }
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var seen: [String] = []
    private var firstSeen: [String: Date] = [:]
    private var live: [String: AXUIElement] = [:]
    private var scanTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    /// The banner window last seen, and the widgets' windows (never banners).
    private var knownWindow: AXUIElement?
    private var widgetWindows: [AXUIElement] = []
    #if DEBUG
    private var firstChange: Date?
    private var lastChange: Date?
    #endif

    var isRunning: Bool { observer != nil }

    func start() {
        guard observer == nil else { return }
        guard AXIsProcessTrusted() else { Log.info("messages: no Accessibility permission yet"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        pid = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let reader = Unmanaged<NotificationBannerReader>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { reader.changed(name, element: element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Log.error("messages: couldn't watch Notification Center")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var watched: [String] = []
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification] {
            if AXObserverAddNotification(created, element, name as CFString, me) == .success { watched.append(name) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        Log.info("messages: watching Notification Center (\(watched.joined(separator: ", ")))")
        // Notification Center restarts now and then: watch the new one.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard launched?.bundleIdentifier == Self.bundleID, let self else { return }
                self.stop()
                self.start()
            }
        }
        // What's already up isn't new.
        seen = Self.scanWindows(pid: pid).banners.map(\.id)
        refresh()
    }

    /// Puts the window where it belongs now (after a setting changed).
    func refresh() { scan() }

    /// Back where macOS had it: on quitting, or when hiding is turned off.
    func restore() {
        if let window = Self.scanWindows(pid: pid).window { Self.place(window, hidden: false) }
    }

    func stop() {
        restore()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        scanTask?.cancel()
        persistTask?.cancel()
    }

    /// Something changed in Notification Center. A new banner window goes out of
    /// sight at once, before its banner is really drawn, if hiding is on at all;
    /// then the banners decide (an app the island doesn't show brings it back).
    private func changed(_ notification: String, element: AXUIElement) {
        #if DEBUG
        // A new burst of changes (none for a second): time from here.
        if lastChange.map({ Date.now.timeIntervalSince($0) > 1 }) ?? true { firstChange = .now }
        lastChange = .now
        if UserDefaults.standard.bool(forKey: "DebugAXEvents") {
            Log.info("messages: event \(notification) on \(Self.string(element, kAXRoleAttribute))/\(Self.string(element, kAXSubroleAttribute)) parent \(Self.parentRole(element)) at +\(Int(Date.now.timeIntervalSince(firstChange ?? .now) * 1000)) ms")
        }
        #endif
        scan()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // Again a moment later: a banner's text can still be filling in.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        let app = AXUIElementCreateApplication(pid)
        guard let window = dialogWindow(app) else { return }
        // What's in it, by structure alone: banners sit right in its scroll area;
        // the panel puts its list (and an Edit Widgets button) there instead.
        let layout = Self.layout(of: window)
        // A banner arriving: out of sight before reading what it says.
        if hidesBanner(""), !layout.panelOpen, !layout.banners.isEmpty, knownWindow.map({ !CFEqual($0, window) }) ?? true {
            Self.move(window, to: Self.hiddenOrigin)
            #if DEBUG
            if let first = firstChange { Log.info("messages: banner window moved \(Int(Date.now.timeIntervalSince(first) * 1000)) ms after the first change") }
            #endif
        }
        knownWindow = window
        let found = (banners: layout.banners.compactMap(Self.banner), window: Optional(window), panelOpen: layout.panelOpen)
        live = Dictionary(found.banners.map { ($0.id, $0.element) }, uniquingKeysWith: { a, _ in a })
        for id in firstSeen.keys where live[id] == nil { firstSeen[id] = nil }
        // Only once it has something to say: an empty banner is still being filled in.
        for banner in found.banners where !seen.contains(banner.id) && !(banner.title.isEmpty && banner.body.isEmpty) {
            seen.append(banner.id)
            if seen.count > 200 { seen.removeFirst(100) }
            firstSeen[banner.id] = .now
            #if DEBUG
            if let first = firstChange { Log.info("messages: banner read \(Int(Date.now.timeIntervalSince(first) * 1000)) ms after Notification Center's first change") }
            firstChange = nil
            #endif
            onBanner(banner)
        }
        place(found)
    }

    /// Out of sight while every banner up is one the island shows. On screen for
    /// the panel, for an app the island doesn't show, for an alert that's
    /// waiting for an answer, whenever hiding is off, and as soon as the last
    /// banner has gone: macOS then hides the window for next time and nothing
    /// can move it until it's back, so it must rest where macOS put it (or a
    /// quit or crash would leave every banner out of sight).
    private func place(_ found: (banners: [Banner], window: AXUIElement?, panelOpen: Bool)) {
        guard let window = found.window else { return }
        let waiting = found.banners.contains { (firstSeen[$0.id].map { Date.now.timeIntervalSince($0) } ?? 0) > Self.persistentAfter }
        let hide = hidesBanner("") && !found.banners.isEmpty && !found.panelOpen && !waiting
            && found.banners.allSatisfy { hidesBanner($0.appName) }
        Self.place(window, hidden: hide)
        persistTask?.cancel()
        if hide {
            persistTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.persistentAfter + 0.5))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    /// Notification Center's banner window, skipping the desktop widgets' windows
    /// (each asked once, then remembered).
    private func dialogWindow(_ app: AXUIElement) -> AXUIElement? {
        for w in Self.children(app, kAXWindowsAttribute) where !widgetWindows.contains(where: { CFEqual($0, w) }) {
            if Self.string(w, kAXSubroleAttribute) == "AXSystemDialog" { return w }
            widgetWindows.append(w)
        }
        return nil
    }

    // MARK: opening

    /// Opens the notification as a click on it would, straight to its
    /// conversation: by pressing its banner while there is one, or else its
    /// entry in Notification Center (whose panel opens for a moment).
    func open(id: String) async -> Bool {
        if let banner = live[id] ?? Self.scanWindows(pid: pid).banners.first(where: { $0.id == id })?.element,
           AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success {
            Log.info("messages: pressed its banner")
            return true
        }
        guard let clock = Self.menuBarClock() else { return false }
        AXUIElementPerformAction(clock, kAXPressAction as CFString)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            if let item = Self.listItem(pid: pid, id: id) {
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                Log.info("messages: pressed it in Notification Center (\(Self.string(item, kAXSubroleAttribute)), parent \(Self.parentRole(item))): \(result.rawValue)")
                if result == .success { return true }
            }
        }
        AXUIElementPerformAction(clock, kAXPressAction as CFString)   // not there: close the panel again
        return false
    }

    // MARK: reading Notification Center

    /// The banners on screen, the window they're in, and whether the panel
    /// (Notification Center's list) is open instead.
    static func scanWindows(pid: pid_t) -> (banners: [Banner], window: AXUIElement?, panelOpen: Bool) {
        let app = AXUIElementCreateApplication(pid)
        guard let w = children(app, kAXWindowsAttribute).first(where: { string($0, kAXSubroleAttribute) == "AXSystemDialog" }) else { return ([], nil, false) }
        let layout = layout(of: w)
        return (layout.banners.compactMap(banner), w, layout.panelOpen)
    }

    static func banners(pid: pid_t) -> [Banner] { scanWindows(pid: pid).banners }

    /// The banner elements in the window, and whether it's the panel: banners are
    /// the scroll area's own children; the panel's notifications are inside its
    /// list (and look like banners too), beside an Edit Widgets button.
    private static func layout(of window: AXUIElement) -> (banners: [AXUIElement], panelOpen: Bool) {
        guard let area = scrollArea(in: window) else { return ([], false) }
        var banners: [AXUIElement] = []
        var panelOpen = false
        for child in children(area, kAXChildrenAttribute) {
            let id = string(child, kAXIdentifierAttribute)
            if id == "AXNotificationListItems" || id == "widget-editor-button" { panelOpen = true; continue }
            if string(child, kAXSubroleAttribute) == "AXNotificationCenterBanner" { banners.append(child) }
        }
        return (panelOpen ? [] : banners, panelOpen)
    }

    private static func scrollArea(in e: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 5 else { return nil }
        for child in children(e, kAXChildrenAttribute) {
            if string(child, kAXRoleAttribute) == kAXScrollAreaRole { return child }
            if let found = scrollArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func banner(_ e: AXUIElement) -> Banner? {
        let id = string(e, kAXIdentifierAttribute)
        guard !id.isEmpty else { return nil }
        var parts: [String: String] = [:]
        for text in children(e, kAXChildrenAttribute) where string(text, kAXRoleAttribute) == kAXStaticTextRole {
            parts[string(text, kAXIdentifierAttribute)] = string(text, kAXValueAttribute)
        }
        let title = parts["title"] ?? "", subtitle = parts["subtitle"] ?? "", body = parts["body"] ?? ""
        return Banner(id: id, appName: MessageInfo.appName(fromBannerDescription: string(e, kAXDescriptionAttribute), title: title),
                      title: title, subtitle: subtitle, body: body, element: e)
    }

    /// The notification with this id in the open panel's list.
    private static func listItem(pid: pid_t, id: String) -> AXUIElement? {
        func find(_ e: AXUIElement, _ depth: Int, inList: Bool) -> AXUIElement? {
            guard depth < 12 else { return nil }
            let list = inList || string(e, kAXIdentifierAttribute) == "AXNotificationListItems"
            if list, string(e, kAXIdentifierAttribute) == id { return e }
            for c in children(e, kAXChildrenAttribute) { if let hit = find(c, depth + 1, inList: list) { return hit } }
            return nil
        }
        for w in children(AXUIElementCreateApplication(pid), kAXWindowsAttribute) where string(w, kAXSubroleAttribute) == "AXSystemDialog" {
            if let hit = find(w, 0, inList: false) { return hit }
        }
        return nil
    }

    /// The menu bar clock, which opens Notification Center: the bar's last item.
    private static func menuBarClock() -> AXUIElement? {
        guard let screen = NSScreen.screens.first else { return nil }
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(screen.frame.width - 30), 12, &hit)
        guard let hit, string(hit, kAXIdentifierAttribute).lowercased().contains("clock") else { return nil }
        return hit
    }

    private static func parentRole(_ e: AXUIElement) -> String {
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let parent else { return "" }
        return string(parent as! AXUIElement, kAXRoleAttribute)
    }

    private static func window(of e: AXUIElement) -> AXUIElement? {
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &w) == .success, let w else { return nil }
        return (w as! AXUIElement)
    }

    /// Well above any screen. macOS keeps the window at the main screen's top-left.
    static let hiddenOrigin = CGPoint(x: 0, y: -5000)

    /// Puts the banner window above the screen, or back where macOS keeps it.
    private static func place(_ window: AXUIElement, hidden: Bool) {
        move(window, to: hidden ? hiddenOrigin : .zero)
    }

    private static func move(_ window: AXUIElement, to origin: CGPoint) {
        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
    }

    private static func children(_ e: AXUIElement, _ key: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ key: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }
}
