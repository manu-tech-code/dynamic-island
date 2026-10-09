import AppKit
import IslandCore

/// Optional menu bar icon. Secondary to the island's own right-click menu,
/// because on a crowded menu bar it can end up hidden under the ears.
final class StatusItemController: NSObject {
    private let env: AppEnvironment
    private let islands: IslandManager
    private var item: NSStatusItem?
    private var dashboardItem: NSMenuItem?

    init(env: AppEnvironment, islands: IslandManager) {
        self.env = env
        self.islands = islands
        super.init()
        apply(visible: env.settings.settings.showMenuBarIcon)
        whenChanged({ [env] in env.settings.settings.showMenuBarIcon }) { [weak self] in self?.apply(visible: $0) }
        whenChanged({ [env] in env.settings.settings.hotKey }) { [weak self] in self?.showShortcut($0) }
    }

    private func apply(visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Dynamic Island")
            let menu = NSMenu()
            dashboardItem = menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
            showShortcut(env.settings.settings.hotKey)
            menu.addItem(withTitle: "Open Shelf", action: #selector(openShelf), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Dynamic Island", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            dashboardItem = nil
        }
    }

    /// The dashboard's shortcut beside its item, as set in Settings; none, no key.
    private func showShortcut(_ spec: HotKeySpec?) {
        guard let dashboardItem else { return }
        let key = spec?.menuKey
        dashboardItem.keyEquivalent = key ?? ""
        dashboardItem.keyEquivalentModifierMask = key == nil ? [] : NSEvent.ModifierFlags(carbon: spec?.carbonModifiers ?? 0)
    }

    @objc private func openDashboard() { islands.toggleDashboard() }
    @objc private func openSettings() { env.openSettings() }
    @objc private func openShelf() { islands.primary?.model.openShelf() }
    @objc private func checkForUpdates() { env.updates.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
