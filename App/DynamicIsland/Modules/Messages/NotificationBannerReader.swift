import AppKit
import ApplicationServices
import IslandCore

/// Reads macOS's notification banners as they appear. Every app's banners are
/// drawn by one system process (Notification Center), each as an element with
/// the app, a title, a subtitle and a body, and actions to open or close it.
/// Accessibility lets us read them, with the permission the HUD already uses.
/// It sees only what macOS shows: each app's notification settings and Focus apply.
final class NotificationBannerReader {
    struct Banner {
        /// Notification Center's own id for the banner; the same while it's on screen.
        let id: String
        let appName: String
        let title: String
        let subtitle: String
        let body: String
        /// The banner itself, to open or close it later.
        let element: AXUIElement
    }

    static let bundleID = "com.apple.notificationcenterui"

    var onBanner: (Banner) -> Void = { _ in }
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var seen: [String] = []
    private var scanTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?

    var isRunning: Bool { observer != nil }

    func start() {
        guard observer == nil else { return }
        guard AXIsProcessTrusted() else { Log.info("messages: no Accessibility permission yet"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        pid = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let reader = Unmanaged<NotificationBannerReader>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { reader.changed(name) }
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
        scan()
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        scanTask?.cancel()
    }

    /// Something changed in Notification Center: look for new banners, once
    /// the burst of changes a banner arriving makes has settled a little.
    /// Something changed in Notification Center: look for new banners at once,
    /// so one can be closed before it's really on screen, and again a moment
    /// later in case its text was still being filled in.
    private func changed(_ notification: String) {
        scan()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        // Only once it has something to say: an empty banner is still being filled in.
        for banner in Self.banners(pid: pid) where !seen.contains(banner.id) && !(banner.title.isEmpty && banner.body.isEmpty) {
            seen.append(banner.id)
            if seen.count > 200 { seen.removeFirst(100) }
            onBanner(banner)
        }
    }

    /// Closes macOS's own banner, as its ✕ would. That also takes the
    /// notification out of Notification Center's list.
    @discardableResult
    static func close(_ banner: Banner) -> Bool {
        var names: CFArray?
        AXUIElementCopyActionNames(banner.element, &names)
        guard let close = ((names as? [String]) ?? []).first(where: { $0.hasPrefix("Name:Close") }) else { return false }
        return AXUIElementPerformAction(banner.element, close as CFString) == .success
    }

    // MARK: reading the banners

    static func banners(pid: pid_t) -> [Banner] {
        let app = AXUIElementCreateApplication(pid)
        var found: [Banner] = []
        for window in children(app, kAXWindowsAttribute) where string(window, kAXSubroleAttribute) == "AXSystemDialog" {
            collect(window, depth: 0, into: &found)
        }
        return found
    }

    private static func collect(_ e: AXUIElement, depth: Int, into found: inout [Banner]) {
        guard depth < 8 else { return }
        if string(e, kAXSubroleAttribute) == "AXNotificationCenterBanner", let banner = banner(e) {
            found.append(banner)
            return
        }
        for child in children(e, kAXChildrenAttribute) { collect(child, depth: depth + 1, into: &found) }
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
