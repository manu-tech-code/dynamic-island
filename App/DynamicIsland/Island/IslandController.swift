import AppKit
import IslandCore
import SwiftUI

/// Borderless, non-activating panel above the menu bar. Never key, never
/// main, so clicking the island doesn't take focus from the user's app.
final class IslandPanel: NSPanel {
    /// Only while opened from the keyboard, so Esc and Tab work. A
    /// non-activating panel can be key without activating the app.
    var allowsKey = false
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Pointer moves over the island while the panel takes mouse events. The
    /// panel is never key, so they only arrive through an always-active tracking area.
    var onPointerMoved: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerMoved?()
    }
}

/// One island on one display: its panel, hit testing, hover, gestures and menu.
final class IslandController: NSObject {
    /// Room for the tallest dashboard (three widget rows) plus the glow.
    static let panelSize = CGSize(width: 860, height: 600)

    let displayID: CGDirectDisplayID
    let model: IslandViewModel
    private let env: AppEnvironment
    private let panel: IslandPanel
    private let lockIsland: LockScreenIsland
    private var screenTop: CGFloat = 0
    private var inside = false
    private var hoverOpenTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var concealTask: Task<Void, Never>?
    /// The pointer was over the island's panel at the last move.
    private var pointerWasNear = true
    /// The song last seen, so a new one can show its title.
    private var lastTrack: String?
    private var scrollAccumulated: CGFloat = 0
    private var scrollHandled = false

    init(screen: NSScreen, displayID: CGDirectDisplayID, env: AppEnvironment) {
        self.displayID = displayID
        self.env = env
        model = IslandViewModel(env: env, notch: Self.notch(for: screen))
        lockIsland = LockScreenIsland(notch: model.notch)
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Dynamic Island")
        let host = FirstMouseHostingView(rootView: IslandRootView(model: model).environment(env))
        host.sizingOptions = []
        panel.contentView = host
        host.onPointerMoved = { [weak self] in self?.pointerMoved(to: NSEvent.mouseLocation) }
        update(screen: screen)
        panel.orderFrontRegardless()
        model.presentMenu = { [weak self] menu in self?.popUp(menu) }
        panel.onCancel = { [weak self] in self?.model.collapse() }
        // Closing an open state with the pointer elsewhere: a hidden island tucks back in.
        whenChanged({ [model] in model.isOpen }) { [weak self] open in
            guard let self, !open, self.model.hidesUntilHover else { return }
            self.updateReveal(at: NSEvent.mouseLocation)
        }
        // Hand the keyboard back once the island closes.
        whenChanged({ [model] in model.isOpen }) { [weak self] open in
            guard let self, !open, self.panel.isKeyWindow else { return }
            self.panel.allowsKey = false
            self.panel.orderOut(nil)
            if !self.hiddenForFullScreen { self.panel.orderFrontRegardless() }
        }
        // Full-screen apps: hide or show per the user's choice.
        whenChanged({ [weak self] in self?.shouldHideForFullScreen ?? false }) { [weak self] hide in
            self?.setHiddenForFullScreen(hide)
        }
        whenChanged({ [model] in "\(model.contentKey) \(Int(model.outerSize.width))×\(Int(model.outerSize.height))" }) { [displayID] in
            Log.info("island \(displayID): \($0)")
        }
        // A new song shows its title for a moment (not the first one seen, at launch).
        lastTrack = Self.trackKey(env.nowPlaying.info)
        whenChanged({ [env] in Self.trackKey(env.nowPlaying.info) }) { [weak self] track in
            guard let self else { return }
            defer { self.lastTrack = track }
            guard self.lastTrack != nil, track != nil, self.env.nowPlaying.info?.isPlaying == true else { return }
            self.model.announceTrack()
        }
        // Locked: the lock island takes the island's place until the unlock animation is over.
        lockIsland.onFinished = { [weak self] in self?.setIslandVisible(true) }
        whenChanged({ [env] in env.lock.isLocked }) { [weak self] locked in self?.setLocked(locked) }
    }

    private static func trackKey(_ info: NowPlayingInfo?) -> String? {
        guard let info, !info.title.isEmpty else { return nil }
        return info.title + "\n" + info.artist
    }

    static func notch(for screen: NSScreen) -> NotchRect {
        NotchMath.notch(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                        auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
    }

    func update(screen: NSScreen) {
        let notch = Self.notch(for: screen)
        if model.notch != notch { model.notch = notch }
        screenTop = screen.frame.maxY
        let size = Self.panelSize
        panel.setFrame(CGRect(x: notch.rect.midX - size.width / 2, y: screenTop - size.height, width: size.width, height: size.height), display: true)
        lockIsland.update(notch: notch, screenTop: screenTop)
        // Re-assert: these flags can be dropped when a window is reordered.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        Log.info("island on display \(displayID): notch \(notch.rect) hardware=\(notch.isHardware)")
    }

    func close() {
        hoverOpenTask?.cancel()
        leaveTask?.cancel()
        lockIsland.close()
        panel.orderOut(nil)
    }

    // MARK: lock

    private func setLocked(_ locked: Bool) {
        if locked {
            hoverOpenTask?.cancel()
            leaveTask?.cancel()
            model.collapse()
            panel.ignoresMouseEvents = true
            guard model.settings.lockIndicator else { return }
            setIslandVisible(false)
            lockIsland.setLocked(true, reduceMotion: model.reduceMotion)
        } else if lockIsland.isShowing {
            lockIsland.setLocked(false, reduceMotion: model.reduceMotion)
        } else {
            setIslandVisible(true)
        }
    }

    /// Hidden while the lock shows; fades back in after the lock has gone into the notch.
    private func setIslandVisible(_ visible: Bool) {
        guard visible else { panel.alphaValue = 0; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 1
        }
    }

    /// Current island outline in global screen coordinates.
    var islandRect: CGRect {
        let s = model.outerSize
        return CGRect(x: model.notch.rect.midX - s.width / 2, y: screenTop - s.height, width: s.width, height: s.height)
    }

    func contains(_ p: NSPoint) -> Bool { islandRect.insetBy(dx: -3, dy: -3).contains(p) }

    // MARK: pointer

    func pointerMoved(to p: NSPoint) {
        guard !env.lock.isLocked else { return }
        // Most moves are nowhere near the island (it never leaves its panel):
        // after the first one out there, which settles hover and reveal, skip them.
        let near = p.y >= screenTop - Self.panelSize.height && abs(p.x - model.notch.rect.midX) <= Self.panelSize.width / 2
        defer { pointerWasNear = near }
        guard near || pointerWasNear else { return }
        if model.hidesUntilHover { updateReveal(at: p) }
        let now = contains(p)
        if panel.ignoresMouseEvents == now { panel.ignoresMouseEvents = !now }
        // The title drops down only while the pointer is on the track itself.
        let f = panel.frame
        model.setOverMedia(now && model.allowsPeek && model.isOverMedia(CGPoint(x: p.x - f.minX, y: f.maxY - p.y)))
        guard now != inside else { return }
        inside = now
        model.setHover(now)
        let s = model.settings
        if now {
            leaveTask?.cancel()
            if s.openOnHover, !model.isOpen {
                hoverOpenTask?.cancel()
                hoverOpenTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(s.hoverDelayMs))
                    guard !Task.isCancelled, let self, self.inside, !self.model.isOpen else { return }
                    self.openFromCompact()
                }
            }
        } else {
            hoverOpenTask?.cancel()
            if s.collapseOnMouseLeave, model.isOpen { scheduleCollapse(after: 0.45) }
        }
    }

    /// When the pointer is at the camera: a short rest on the camera brings the
    /// island out (so a pass across the menu bar doesn't), and leaving the island
    /// tucks it back in a moment later. Open states stay until they close.
    private func updateReveal(at p: NSPoint) {
        let atCamera = isAtCamera(p)
        // The island out for a new song's title: the pointer on it keeps it out.
        let onIsland = (model.revealed || model.announcing) && contains(p)
        if atCamera || onIsland {
            concealTask?.cancel()
            concealTask = nil
            if onIsland, !model.revealed { model.setRevealed(true) }
            guard atCamera, !model.revealed, revealTask == nil else { return }
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, !Task.isCancelled else { return }
                self.revealTask = nil
                if self.isAtCamera(NSEvent.mouseLocation) { self.model.setRevealed(true) }
            }
        } else {
            revealTask?.cancel()
            revealTask = nil
            guard model.revealed, !model.isOpen, concealTask == nil else { return }
            concealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                guard let self, !Task.isCancelled else { return }
                self.concealTask = nil
                if !self.contains(NSEvent.mouseLocation), !self.model.isOpen { self.model.setRevealed(false) }
            }
        }
    }

    /// The camera, or what stays out of the tucked island while music plays.
    private func isAtCamera(_ p: NSPoint) -> Bool {
        if IslandMetrics.revealArea(notch: model.notch.rect).contains(p) { return true }
        guard model.indicatorPhase == .shown, let style = model.playingIndicatorStyle,
              let area = IslandMetrics.playingHoverArea(style: style, notch: model.notch.rect) else { return false }
        return area.contains(p)
    }

    /// A click anywhere outside the island closes it.
    func mouseDownOutside(at p: NSPoint) {
        guard model.isOpen, !contains(p) else { return }
        model.collapse()
    }

    func openFromCompact() {
        switch model.presentation {
        case .compact:
            if let id = model.ranked.primary?.id { model.open(id) }
        case .idle: model.openDashboard()
        default: break
        }
    }

    /// From the keyboard shortcut. The panel takes the keyboard so Esc closes
    /// it and Tab moves between controls; it closes again if the pointer
    /// never comes over.
    func toggleDashboard() {
        guard !env.lock.isLocked else { return }
        model.toggleDashboard()
        if model.isOpen {
            if hiddenForFullScreen { panel.orderFrontRegardless() }
            panel.allowsKey = true
            panel.makeKey()
            if !inside { scheduleCollapse(after: 8) }
        }
    }

    // MARK: full screen

    private(set) var hiddenForFullScreen = false

    private var shouldHideForFullScreen: Bool {
        guard env.fullScreen.isFullScreen(displayID) else { return false }
        if model.isOpen || env.engine.alert != nil { return false }
        switch model.settings.fullScreen {
        case .show: return false
        case .hide: return true
        case .hideWhenIdle:
            let quiet: Set<ActivityKind> = [.backgroundApps, .shelf]
            return model.ranked.visible.allSatisfy { quiet.contains($0.kind) }
        }
    }

    private func setHiddenForFullScreen(_ hide: Bool) {
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        if hide { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        Log.info("island \(displayID): \(hide ? "hidden for" : "back from") full screen")
    }

    func openShelfForDrag() {
        guard !model.isOpen || model.presentation == .shelf else { return }
        Log.info("shelf: opened by a drag")
        model.openShelf(byDrag: true)
    }

    /// The drag let go. If it wasn't dropped on the island, put the shelf away.
    func dragEnded() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.model.shelfOpenedByDrag, !self.inside else { return }
            self.model.collapse()
        }
    }

    /// Opens Now Playing on a page (from a link or shortcut).
    func showNowPlaying(page: NowPlayingPage) {
        guard let id = env.engine.live.first(where: { $0.kind == .nowPlaying })?.id else { return }
        model.open(id)
        if page != .player { model.showPage(page) }
        if !inside { scheduleCollapse(after: 20) }
    }

    private func scheduleCollapse(after seconds: Double) {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.inside else { return }
            self.model.collapse()
        }
    }

    /// Two-finger scroll on the island: pull down to open, push up to close.
    func scroll(_ event: NSEvent) -> Bool {
        guard contains(NSEvent.mouseLocation) else { return false }
        // Lyrics and Up Next are lists; let SwiftUI scroll them.
        if model.hasScrollableContent { return false }
        let isWheel = event.phase == [] && event.momentumPhase == []
        if event.phase == .began { scrollAccumulated = 0; scrollHandled = false }
        if event.phase == .ended || event.phase == .cancelled { scrollAccumulated = 0; scrollHandled = false; return true }
        if event.momentumPhase != [] { return true } // ignore the coast after the fingers lift
        guard !scrollHandled else { return true }
        let down = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? 1 : -1)
        scrollAccumulated += down
        if scrollAccumulated > 24, !model.isOpen {
            scrollHandled = true
            openFromCompact()
        } else if scrollAccumulated < -24, model.isOpen {
            scrollHandled = true
            model.collapse()
        }
        if isWheel {
            // Mouse wheel: no phases, so treat a short burst as one gesture.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                self?.scrollAccumulated = 0
                self?.scrollHandled = false
            }
        }
        return true
    }

    // MARK: menu

    func showMenu() {
        guard !env.lock.isLocked else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, model.isOpen ? "Collapse" : "Open Dashboard", #selector(menuToggle))
        if env.nowPlaying.info != nil {
            add(menu, env.nowPlaying.info?.isPlaying == true ? "Pause" : "Play", #selector(menuPlayPause))
            add(menu, "Next Track", #selector(menuNext))
        }
        if env.engine.alert != nil { add(menu, "Dismiss Alert", #selector(menuDismissAlert)) }
        if model.settings[module: .shelf].enabled {
            add(menu, env.shelf.items.isEmpty ? "Open Shelf" : "Open Shelf (\(env.shelf.items.count))", #selector(menuShelf))
        }
        menu.addItem(.separator())

        let width = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        width.submenu = NSMenu()
        for (title, scale) in [("Narrow", 0.85), ("Standard", 1.0), ("Wide", 1.2)] {
            let item = add(width.submenu!, title, #selector(menuWidth(_:)))
            item.representedObject = scale
            item.state = abs(model.settings.openWidthScale - scale) < 0.01 ? .on : .off
        }
        width.submenu!.addItem(.separator())
        width.submenu!.addItem(withTitle: "Drag the island's edges to set any width", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(width)

        let style = NSMenuItem(title: "Compact Style", action: nil, keyEquivalent: "")
        style.submenu = NSMenu()
        for s in CompactStyle.allCases {
            let item = add(style.submenu!, s.displayName, #selector(menuCompactStyle(_:)))
            item.representedObject = s.rawValue
            item.state = model.settings.compactStyle == s ? .on : .off
        }
        menu.addItem(style)
        let material = NSMenuItem(title: "Material", action: nil, keyEquivalent: "")
        material.submenu = NSMenu()
        for m in IslandMaterial.allCases {
            let item = add(material.submenu!, m.displayName, #selector(menuMaterial(_:)))
            item.representedObject = m.rawValue
            item.state = model.settings.material == m ? .on : .off
        }
        menu.addItem(material)
        menu.addItem(.separator())
        add(menu, env.updates.available.map { "Install Update \($0)…" } ?? "Check for Updates…", #selector(menuUpdates))
        add(menu, "Settings…", #selector(menuSettings)).keyEquivalent = ","
        add(menu, "Quit Dynamic Island", #selector(menuQuit)).keyEquivalent = "q"

        popUp(menu)
    }

    /// Pops a menu at the pointer. The hosting view is flipped (y grows down),
    /// so the point must go through the view, not just the window.
    func popUp(_ menu: NSMenu) {
        guard let view = panel.contentView else { return }
        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: view.convert(inWindow, from: nil), in: view)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func menuToggle() { model.isOpen ? model.collapse() : model.openDashboard() }
    @objc private func menuPlayPause() { env.nowPlaying.togglePlayPause() }
    @objc private func menuShelf() { model.openShelf() }
    @objc private func menuUpdates() { env.updates.checkForUpdates() }
    @objc private func menuWidth(_ item: NSMenuItem) {
        guard let scale = item.representedObject as? Double else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { env.settings.settings.openWidthScale = scale }
    }
    @objc private func menuNext() { env.nowPlaying.next() }
    @objc private func menuDismissAlert() { env.engine.dismissAlert() }
    @objc private func menuSettings() { env.openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuCompactStyle(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let s = CompactStyle(rawValue: raw) else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.18)) { env.settings.settings.compactStyle = s }
    }
    @objc private func menuMaterial(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let m = IslandMaterial(rawValue: raw) else { return }
        env.settings.settings.material = m
    }
}
