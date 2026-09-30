// Spikes 1 + 2: a non-activating panel over the notch that draws the Hybrid
// island with real system glass, plus a glass lab (key window vs non-key panel).
//
//   NotchGlassSpike [--expanded] [--no-lab] [--fullscreen-test]
//
// Everything interesting is logged to ~/Library/Logs/IslandSpikes/NotchGlass.log.

import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    var look: SystemLook!
    var panel: NotchPanel!
    var geometry: NotchGeometry!
    var labWindow: NSWindow?
    var labPanel: NSPanel?
    var statusItem: NSStatusItem!
    var monitors: [Any] = []
    let panelSize = CGSize(width: 760, height: 300)
    let args = Set(CommandLine.arguments.dropFirst())

    func applicationDidFinishLaunching(_ note: Notification) {
        look = SystemLook()
        Log.write("===== NotchGlassSpike launch · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · bundle \(Bundle.main.bundleIdentifier ?? "none")")
        Log.write("SCREENS\n" + NotchGeometry.describeAllScreens())
        model.expanded = args.contains("--expanded")
        if args.contains("--below") { model.compactStyle = .below }
        model.toggleLab = { [weak self] in self?.toggleLab() }
        model.runFullScreenTest = { [weak self] in self?.runFullScreenTest() }
        model.quit = { NSApp.terminate(nil) }
        buildPanel()
        buildStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.logStatusItem() }
        installMouseMonitors()
        if !args.contains("--no-lab") { showLab() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("didChangeScreenParameters\n" + NotchGeometry.describeAllScreens())
            self?.positionPanel()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.snapshot("activeSpaceDidChange")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("panel occlusion visible=\(self.panel.occlusionState.contains(.visible))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.snapshot("after launch") }
        if args.contains("--fullscreen-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.runFullScreenTest() }
        }
    }

    // MARK: panel

    func buildPanel() {
        guard let screen = NotchGeometry.preferredScreen() else { Log.write("no screen"); return }
        geometry = NotchGeometry(screen: screen)
        model.notchSize = geometry.rect.size
        Log.write("NOTCH hardware=\(geometry.isHardware) rect=\(geometry.rect) menuBarHeight=\(geometry.menuBarHeight)")

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = FirstMouseHostingView(rootView: IslandView(model: model, look: look))
        host.sizingOptions = []
        panel.contentView = host
        positionPanel()
        panel.orderFrontRegardless()
        Log.write("PANEL level=\(panel.level.rawValue) behavior=\(panel.collectionBehavior.rawValue) frame=\(panel.frame) windowNumber=\(panel.windowNumber)")
    }

    func positionPanel() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        geometry = NotchGeometry(screen: screen)
        model.notchSize = geometry.rect.size
        let f = CGRect(x: geometry.rect.midX - panelSize.width / 2, y: screen.frame.maxY - panelSize.height,
                       width: panelSize.width, height: panelSize.height)
        panel.setFrame(f, display: true)
        // Re-assert: behaviour flags reportedly get dropped on some reorders.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Island rect in global screen coordinates for hit testing.
    var islandScreenRect: CGRect {
        let s = model.outerSize
        return CGRect(x: geometry.rect.midX - s.width / 2, y: geometry.screen.frame.maxY - s.height, width: s.width, height: s.height)
    }

    func installMouseMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.geometry != nil else { return }
            let p = NSEvent.mouseLocation
            let inside = self.islandScreenRect.insetBy(dx: -2, dy: -2).contains(p)
            if e.type == .leftMouseDown, !inside, self.model.expanded {
                Log.write("click outside → collapse")
                self.model.expanded = false
            }
            if self.panel.ignoresMouseEvents == inside { self.panel.ignoresMouseEvents = !inside }
            if self.model.hover != inside { self.model.hover = inside }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { e in handler(e); return e } as Any)
    }

    // MARK: glass lab

    func showLab() {
        if labWindow == nil {
            let close: () -> Void = { [weak self] in self?.hideLab() }
            let quit: () -> Void = { NSApp.terminate(nil) }
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 400),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Glass lab · key window"
            w.titlebarAppearsTransparent = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: GlassLab(title: "Key window (normal NSWindow)", look: look, onClose: close, onQuit: quit))
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.labPanel?.orderOut(nil)
            }
            labWindow = w

            let p = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 820, height: 400),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isReleasedWhenClosed = false
            p.contentView = FirstMouseHostingView(rootView: GlassLab(title: "Non-key panel (like the island)", look: look, onClose: close, onQuit: quit))
            labPanel = p
        }
        guard let w = labWindow, let p = labPanel, let screen = NotchGeometry.preferredScreen() else { return }
        // Stack both below the menu bar from the actual frames, so macOS can't
        // push the window down after we've placed the panel.
        let vf = screen.visibleFrame
        w.setFrameTopLeftPoint(CGPoint(x: vf.midX - w.frame.width / 2, y: vf.maxY - 8))
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        p.setFrameTopLeftPoint(CGPoint(x: w.frame.minX, y: w.frame.minY - 10))
        p.orderFrontRegardless()
        Log.write("LAB window=\(w.frame) panel=\(p.frame)")
    }

    func hideLab() {
        labWindow?.orderOut(nil)
        labPanel?.orderOut(nil)
        Log.write("LAB hidden")
    }

    func toggleLab() {
        if let w = labWindow, w.isVisible { hideLab() } else { showLab() }
    }

    func logStatusItem() {
        guard let bw = statusItem.button?.window else { Log.write("STATUS ITEM no window"); return }
        Log.write("STATUS ITEM visible=\(statusItem.isVisible) frame=\(bw.frame) occlusionVisible=\(bw.occlusionState.contains(.visible)) onScreen=\(bw.screen?.localizedName ?? "none")")
    }

    // MARK: status item

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Island spike")
        let menu = NSMenu()
        menu.addItem(withTitle: "Expand / collapse", action: #selector(toggleExpanded), keyEquivalent: "")
        menu.addItem(.separator())
        for m in IslandMaterial.allCases {
            let i = NSMenuItem(title: "Material: \(m.rawValue)", action: #selector(setMaterial(_:)), keyEquivalent: "")
            i.representedObject = m.rawValue; menu.addItem(i)
        }
        for v in GlassVariant.allCases {
            let i = NSMenuItem(title: "Glass: \(v.rawValue)", action: #selector(setVariant(_:)), keyEquivalent: "")
            i.representedObject = v.rawValue; menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show / hide glass lab", action: #selector(labAction), keyEquivalent: "")
        menu.addItem(withTitle: "Run full-screen test", action: #selector(fsAction), keyEquivalent: "")
        menu.addItem(withTitle: "Log window snapshot", action: #selector(snapAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    @objc func toggleExpanded() { model.expanded.toggle() }
    @objc func setMaterial(_ s: NSMenuItem) { model.material = IslandMaterial(rawValue: s.representedObject as! String)!; Log.write("material → \(model.material.rawValue)") }
    @objc func setVariant(_ s: NSMenuItem) { model.variant = GlassVariant(rawValue: s.representedObject as! String)!; Log.write("variant → \(model.variant.rawValue)") }
    @objc func labAction() { toggleLab() }
    @objc func fsAction() { runFullScreenTest() }
    @objc func snapAction() { snapshot("manual") }

    // MARK: diagnostics

    func snapshot(_ label: String) {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = list.first { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Log.write("SNAPSHOT [\(label)] panel onActiveSpace=\(panel.isOnActiveSpace) visible=\(panel.isVisible) occlusionVisible=\(panel.occlusionState.contains(.visible)) inOnScreenList=\(mine != nil) cgLayer=\(mine?[kCGWindowLayer as String] ?? "-") frontApp=\(frontApp) mainScreen=\(NSScreen.main?.localizedName ?? "?")")
    }

    func runFullScreenTest() {
        Log.write("FULLSCREEN TEST begin")
        snapshot("fs: before")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let w = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 700, height: 420),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Island spike · full-screen test (closes itself)"
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView:
            VStack(spacing: 12) {
                Text("Full-screen test").font(.largeTitle.bold())
                Text("Look at the notch: the island should still be there.")
                Text("This window leaves full screen and closes by itself in about 10 seconds.").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)))
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { w.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.snapshot("fs: inside full-screen space") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { w.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            self.snapshot("fs: after exit")
            w.close()
            NSApp.setActivationPolicy(.accessory)
            Log.write("FULLSCREEN TEST end")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
