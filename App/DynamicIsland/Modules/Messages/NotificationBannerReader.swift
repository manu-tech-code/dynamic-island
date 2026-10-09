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
/// is moved above the screens, not closed: closing a banner (its ✕) clears it
/// from Notification Center, while a banner out of sight times out into the
/// list as usual and can still be pressed to open its conversation. The window
/// goes back exactly where it was as soon as its banners have gone (macOS hides
/// it then, and shows it in its own place for the next banners); while it's
/// away, where it was is saved, for a crash or a forced quit (`recoverIfNeeded`).
final class NotificationBannerReader {
    struct Banner {
        /// Notification Center's id for the notification: the same on the banner
        /// and later in Notification Center's list.
        let id: String
        /// The app it's from; nil when the banner doesn't say in a way we can read.
        let appName: String?
        /// The banner has its description yet (it fills in a moment after it appears).
        let described: Bool
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
    /// Where the banner window was, saved while it's out of sight, so a crash can't leave it there.
    static let movedKey = "messages.bannerWindowMoved"

    var onBanner: (Banner) -> Void = { _ in }
    /// Whether macOS's own banner for this app should stay out of sight.
    var hidesBanner: (String) -> Bool = { _ in false }
    /// Whether it should for any app at all (decided before a banner says whose it is).
    var hidesAny: () -> Bool = { false }
    /// Whether the island shows on the display at this point (Accessibility's
    /// coordinates): banners are only kept out of sight where the island is.
    var islandAt: (CGPoint) -> Bool = { _ in true }
    /// The names of the apps on this Mac, to tell which one a banner is from.
    var appNames: () -> [String] = { [] }
    /// Accessibility was switched off for the app while it was reading.
    var onTrustLost: () -> Void = {}

    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var seen: [String] = []
    /// Banners already up when watching began: the island never showed them, so
    /// macOS's stay on screen.
    private var preexisting: Set<String> = []
    private var firstSeen: [String: Date] = [:]
    /// Banners noticed with only part of their text, to wait a moment for the rest.
    private var noticed: [String: Date] = [:]
    /// When each banner up was first seen, shown on the island or not.
    private var arrived: [String: Date] = [:]
    /// How long a banner the island hasn't shown may stay out of sight while its text fills in.
    static let fillingIn: TimeInterval = 1
    private var live: [String: AXUIElement] = [:]
    private var scanTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    /// Notification Center quitting (macOS starts it again at once).
    private var exitSource: DispatchSourceProcess?
    private var reattachTask: Task<Void, Never>?
    /// The banner window last seen, and the desktop widgets' windows (never banners).
    private var knownWindow: AXUIElement?
    private var widgetWindows: [AXUIElement] = []
    /// The window this app moved out of sight, and where it was.
    private var moved: (window: AXUIElement, origin: CGPoint)?
    /// Where macOS last had the window: the place to put it back when its own
    /// position can't be read.
    private var lastOrigin = CGPoint.zero
    #if DEBUG
    private var firstChange: Date?
    private var lastChange: Date?
    #endif

    var isRunning: Bool { observer != nil }

    // MARK: a window left out of sight

    /// The app crashed or was forced to quit while a banner was out of sight.
    /// macOS puts its window back for the next run of banners by itself, so at
    /// most the banner that was up stays unseen (it's still in Notification
    /// Center); if that one is still up now, its window goes back where it was.
    static func recoverIfNeeded() {
        guard UserDefaults.standard.object(forKey: movedKey) != nil else { return }
        let spot = UserDefaults.standard.dictionary(forKey: movedKey) ?? [:]
        UserDefaults.standard.removeObject(forKey: movedKey)
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let window = scanWindows(pid: app.processIdentifier).window,
              let now = position(window), now.y < hiddenY + 100 else { return }
        let origin = CGPoint(x: spot["x"] as? Double ?? 0, y: spot["y"] as? Double ?? 0)
        Log.info("messages: the banner window was left out of sight last time; putting it back")
        move(window, to: origin)
    }

    /// Quitting from the Terminal or Activity Monitor (a signal rather than Quit):
    /// the window goes back first.
    func restoreOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: watching

    func start() {
        guard observer == nil else { return }
        guard AXIsProcessTrusted() else { Log.info("messages: no Accessibility permission yet"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        pid = app.processIdentifier
        // A busy Notification Center mustn't hold the island up: answers within a second or not at all.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
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
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification,
                     kAXUIElementDestroyedNotification, kAXValueChangedNotification] {
            if AXObserverAddNotification(created, element, name as CFString, me) == .success { watched.append(name) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        Log.info("messages: watching Notification Center (\(watched.joined(separator: ", ")))")
        // Notification Center restarts now and then (macOS doesn't announce it to
        // apps): its process ending is the sign, then watch the new one.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reattach() } }
        source.resume()
        exitSource = source
        // What's already up isn't new.
        seen = Self.scanWindows(pid: pid).banners.map(\.id)
        preexisting = Set(seen)
        refresh()
    }

    /// Puts the window where it belongs now (after a setting changed).
    func refresh() { scan() }

    /// Back where macOS had it: on quitting, or when hiding is turned off.
    func restore() {
        guard let m = moved else { return }
        if Self.move(m.window, to: m.origin) { Log.info("messages: banner window back") }
        moved = nil
        UserDefaults.standard.removeObject(forKey: Self.movedKey)
    }

    func stop() {
        restore()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        exitSource?.cancel()
        exitSource = nil
        scanTask?.cancel()
        persistTask?.cancel()
        knownWindow = nil
        widgetWindows = []
        noticed = [:]
    }

    /// Notification Center quit: watch the new one as soon as macOS has started it.
    private func reattach() {
        moved = nil   // its windows went with it
        UserDefaults.standard.removeObject(forKey: Self.movedKey)
        stop()
        Log.info("messages: Notification Center quit; waiting for it to start again")
        reattachTask?.cancel()
        reattachTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first, !app.isTerminated {
                    self.start()
                    return
                }
            }
        }
    }

    /// Something changed in Notification Center: read it now, and again a little
    /// later, as banners fill in their text over a few moments (longer on a busy Mac).
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
            for delay in [80, 250, 600, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    private func scan() {
        let app = AXUIElementCreateApplication(pid)
        var probe: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &probe) == .apiDisabled {
            Log.info("messages: Accessibility was switched off")
            stop()
            onTrustLost()
            return
        }
        guard let window = dialogWindow(app) else { return }
        // What's in it, by structure alone: banners sit right in its scroll area;
        // the panel puts its list (and an Edit Widgets button) there instead.
        let layout = Self.layout(of: window)
        let names = appNames()
        let banners = layout.banners.compactMap { Self.banner($0, appNames: names) }
        let isNew = knownWindow.map { !CFEqual($0, window) } ?? true
        knownWindow = window
        let unseen = banners.filter { !seen.contains($0.id) }
        // Many "new banners" at once is the panel's list, not banners arriving
        // (if macOS ever lays it out in a way this doesn't recognise): leave it be.
        if unseen.count > 3 {
            Log.info("messages: \(unseen.count) notifications at once: taken for Notification Center's list")
            seen.append(contentsOf: unseen.map(\.id))
            return
        }
        // A banner arriving: out of sight before reading what it says, when its app
        // is one the island shows, or isn't known yet.
        if isNew, !layout.panelOpen, !banners.isEmpty, hides(banners) {
            place(window, hidden: true)
            #if DEBUG
            if let first = firstChange { Log.info("messages: banner window moved \(Int(Date.now.timeIntervalSince(first) * 1000)) ms after the first change") }
            #endif
        }
        live = Dictionary(banners.map { ($0.id, $0.element) }, uniquingKeysWith: { a, _ in a })
        for id in firstSeen.keys where live[id] == nil { firstSeen[id] = nil }
        for id in noticed.keys where live[id] == nil { noticed[id] = nil }
        for id in arrived.keys where live[id] == nil { arrived[id] = nil }
        for b in banners where arrived[b.id] == nil { arrived[b.id] = .now }
        for banner in unseen where !(banner.title.isEmpty && banner.body.isEmpty) {
            // The title can come before the rest: wait a moment for the body.
            if banner.body.isEmpty || !banner.described {
                let since = noticed[banner.id] ?? .now
                noticed[banner.id] = since
                if Date.now.timeIntervalSince(since) < 0.5 { continue }
            }
            noticed[banner.id] = nil
            seen.append(banner.id)
            if seen.count > 200 { seen.removeFirst(100) }
            firstSeen[banner.id] = .now
            #if DEBUG
            if let first = firstChange { Log.info("messages: banner read \(Int(Date.now.timeIntervalSince(first) * 1000)) ms after Notification Center's first change") }
            firstChange = nil
            #endif
            onBanner(banner)
        }
        // Waiting for a body that hasn't come: look again once the wait is over.
        if !noticed.isEmpty, waitTask == nil {
            waitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                self?.waitTask = nil
                self?.scan()
            }
        }
        let waiting = banners.contains { (firstSeen[$0.id].map { Date.now.timeIntervalSince($0) } ?? 0) > Self.persistentAfter }
        let hide = !banners.isEmpty && !layout.panelOpen && !waiting && hides(banners)
        place(window, hidden: hide)
        persistTask?.cancel()
        if hide {
            persistTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.persistentAfter + 0.5))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    /// Out of sight only while every banner up is on the island instead, on a
    /// display with an island. A banner the island hasn't shown (its app is off
    /// or can't be told, it has no text to show, it was up before watching
    /// began) is back on screen within a second: the island never hides
    /// something it isn't showing.
    private func hides(_ banners: [Banner]) -> Bool {
        guard hidesAny(), !banners.contains(where: { preexisting.contains($0.id) }) else { return false }
        if let window = knownWindow, let spot = moved.map({ $0.origin }) ?? Self.position(window), !islandAt(spot) { return false }
        return banners.allSatisfy { b in
            let shown = firstSeen[b.id] != nil
            if !shown {
                // Still filling in? Give it a moment, then it's on screen again.
                guard Date.now.timeIntervalSince(arrived[b.id] ?? .now) < Self.fillingIn else {
                    #if DEBUG
                    Log.info("messages: a banner the island didn't show (app known: \(b.appName != nil), described: \(b.described), title: \(!b.title.isEmpty), body: \(!b.body.isEmpty))")
                    #endif
                    return false
                }
            }
            if let app = b.appName { return hidesBanner(app) }
            return !shown && !b.described
        }
    }

    /// Out of sight, or back exactly where it was: only ever the window this app
    /// moved, so with hiding off, macOS's window is left alone.
    private func place(_ window: AXUIElement, hidden: Bool) {
        if hidden {
            if let m = moved, CFEqual(m.window, window) { return }
            if moved != nil { restore() }   // an earlier window, still away
            // Where macOS put it (unless it's already above the screens).
            let origin = Self.position(window).flatMap { $0.y > Self.hiddenY + 100 ? $0 : nil } ?? lastOrigin
            UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: Self.movedKey)
            if Self.move(window, to: CGPoint(x: origin.x, y: Self.hiddenY)) {
                moved = (window, origin)
                lastOrigin = origin
            } else {
                Log.error("messages: couldn't move macOS's banner window; leaving it be")
                UserDefaults.standard.removeObject(forKey: Self.movedKey)
            }
        } else if moved != nil {
            restore()
        }
    }

    /// Notification Center's banner window, skipping the desktop widgets' windows
    /// (each asked once, then remembered; one that doesn't answer is asked again).
    private func dialogWindow(_ app: AXUIElement) -> AXUIElement? {
        for w in Self.children(app, kAXWindowsAttribute) where !widgetWindows.contains(where: { CFEqual($0, w) }) {
            let subrole = Self.string(w, kAXSubroleAttribute)
            if subrole == "AXSystemDialog" { return w }
            if !subrole.isEmpty { widgetWindows.append(w) }
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
        let wasOpen = Self.scanWindows(pid: pid).panelOpen
        var clock: AXUIElement?
        if !wasOpen {
            clock = Self.menuBarClock()
            guard let clock else { Log.info("messages: no menu bar clock to open Notification Center"); return false }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
        }
        // The panel takes a moment to open and fill its list.
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if let item = Self.listItem(pid: pid, id: id) {
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                Log.info("messages: pressed it in Notification Center: \(result.rawValue)")
                if result == .success { return true }
            }
        }
        if let clock { AXUIElementPerformAction(clock, kAXPressAction as CFString) }   // not there: close the panel again
        return false
    }

    // MARK: reading Notification Center

    /// The banners on screen, the window they're in, and whether the panel
    /// (Notification Center's list) is open instead.
    static func scanWindows(pid: pid_t, appNames: [String] = []) -> (banners: [Banner], window: AXUIElement?, panelOpen: Bool) {
        let app = AXUIElementCreateApplication(pid)
        guard let w = children(app, kAXWindowsAttribute).first(where: { string($0, kAXSubroleAttribute) == "AXSystemDialog" }) else { return ([], nil, false) }
        let layout = layout(of: w)
        return (layout.banners.compactMap { banner($0, appNames: appNames) }, w, layout.panelOpen)
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

    private static func banner(_ e: AXUIElement, appNames: [String]) -> Banner? {
        let id = string(e, kAXIdentifierAttribute)
        guard !id.isEmpty else { return nil }
        var parts: [String: String] = [:]
        for text in children(e, kAXChildrenAttribute) where string(text, kAXRoleAttribute) == kAXStaticTextRole {
            parts[string(text, kAXIdentifierAttribute)] = string(text, kAXValueAttribute)
        }
        let title = parts["title"] ?? "", subtitle = parts["subtitle"] ?? "", body = parts["body"] ?? ""
        let description = string(e, kAXDescriptionAttribute)
        return Banner(id: id, appName: MessageInfo.appName(fromBannerDescription: description, title: title, knownApps: appNames),
                      described: !description.isEmpty, title: title, subtitle: subtitle, body: body, element: e)
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

    /// The menu bar clock, which opens Notification Center: found among the
    /// menu bar's status items by its identifier, wherever the bar is and however
    /// the clock looks (macOS 27 keeps them in MenuBarAgent, earlier versions in
    /// Control Center or SystemUIServer); failing that, the bar's last item on the
    /// main display.
    static func menuBarClock(orByPlace: Bool = true) -> AXUIElement? {
        func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            for child in children(e, kAXChildrenAttribute) {
                if string(child, kAXIdentifierAttribute) == "com.apple.menuextra.clock" { return child }
                if let hit = find(child, depth + 1) { return hit }
            }
            return nil
        }
        for owner in ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first else { continue }
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar" as CFString, &bar) == .success,
                  let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
            if let clock = find(bar as! AXUIElement, 0) { return clock }
        }
        guard orByPlace, let screen = NSScreen.screens.first else { return nil }
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

    /// Above every display, however they're arranged (Accessibility's
    /// coordinates: y grows downward from the top of the main display).
    static var hiddenY: CGFloat {
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return -(top - mainTop) - 5000
    }

    static func position(_ window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    /// Moves the window and checks it went (once more if it didn't).
    @discardableResult
    private static func move(_ window: AXUIElement, to origin: CGPoint) -> Bool {
        for _ in 0..<2 {
            var point = origin
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            if let now = position(window), abs(now.x - origin.x) < 2, abs(now.y - origin.y) < 2 { return true }
        }
        return false
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
