import AppKit
import IslandCore
import SwiftUI

/// Borderless, non-activating panel above the menu bar. Never key, never
/// main, so clicking the island doesn't take focus from the user's app.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One island on one display: its panel, hit testing, hover, gestures and menu.
final class IslandController: NSObject {
    static let panelSize = CGSize(width: 860, height: 340)

    let displayID: CGDirectDisplayID
    let model: IslandViewModel
    private let env: AppEnvironment
    private let panel: IslandPanel
    private var screenTop: CGFloat = 0
    private var inside = false
    private var hoverOpenTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var scrollAccumulated: CGFloat = 0
    private var scrollHandled = false

    init(screen: NSScreen, displayID: CGDirectDisplayID, env: AppEnvironment) {
        self.displayID = displayID
        self.env = env
        model = IslandViewModel(env: env, notch: Self.notch(for: screen))
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
        update(screen: screen)
        panel.orderFrontRegardless()
        whenChanged({ [model] in "\(model.contentKey) \(Int(model.outerSize.width))×\(Int(model.outerSize.height))" }) { [displayID] in
            Log.info("island \(displayID): \($0)")
        }
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
        // Re-assert: these flags can be dropped when a window is reordered.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        Log.info("island on display \(displayID): notch \(notch.rect) hardware=\(notch.isHardware)")
    }

    func close() {
        hoverOpenTask?.cancel()
        leaveTask?.cancel()
        panel.orderOut(nil)
    }

    /// Current island outline in global screen coordinates.
    var islandRect: CGRect {
        let s = model.outerSize
        return CGRect(x: model.notch.rect.midX - s.width / 2, y: screenTop - s.height, width: s.width, height: s.height)
    }

    func contains(_ p: NSPoint) -> Bool { islandRect.insetBy(dx: -3, dy: -3).contains(p) }

    // MARK: pointer

    func pointerMoved(to p: NSPoint) {
        let now = contains(p)
        if panel.ignoresMouseEvents == now { panel.ignoresMouseEvents = !now }
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

    /// For opens that didn't come from the pointer (the keyboard shortcut):
    /// close again if the pointer never comes over.
    func toggleDashboard() {
        model.toggleDashboard()
        if model.isOpen, !inside { scheduleCollapse(after: 6) }
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
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, model.isOpen ? "Collapse" : "Open Dashboard", #selector(menuToggle))
        if env.nowPlaying.info != nil {
            add(menu, env.nowPlaying.info?.isPlaying == true ? "Pause" : "Play", #selector(menuPlayPause))
            add(menu, "Next Track", #selector(menuNext))
        }
        if env.engine.alert != nil { add(menu, "Dismiss Alert", #selector(menuDismissAlert)) }
        menu.addItem(.separator())

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
        add(menu, "Settings…", #selector(menuSettings)).keyEquivalent = ","
        add(menu, "Quit Dynamic Island", #selector(menuQuit)).keyEquivalent = "q"

        let p = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: p, in: panel.contentView)
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
