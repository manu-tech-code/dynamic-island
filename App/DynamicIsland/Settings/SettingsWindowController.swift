import AppKit
import SwiftUI

final class SettingsWindowController {
    private let env: AppEnvironment
    private var window: NSWindow?

    init(env: AppEnvironment) {
        self.env = env
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(env))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Dynamic Island Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 980, height: 720))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
