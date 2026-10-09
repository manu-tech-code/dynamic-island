import AppKit
import SwiftUI

final class SettingsWindowController {
    private let env: AppEnvironment
    private var window: NSWindow?

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Resizable down to `SettingsView.minimumSize`, which fits a 13-inch display
    /// with larger text; it opens at 980×720, or smaller where that doesn't fit,
    /// and remembers the size you leave it at.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(env))
            hosting.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "Dynamic Island Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            let room = NSScreen.main?.visibleFrame.size ?? NSSize(width: 980, height: 720)
            w.setContentSize(NSSize(width: min(980, room.width - 40), height: min(720, room.height - 60)))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("Settings")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
