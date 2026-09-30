import AppKit
import Carbon.HIToolbox

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    let env = AppEnvironment()
    private(set) var islands: IslandManager!
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Bundle.main.bundleURL.path)")
        let settingsWindow = SettingsWindowController(env: env)
        self.settingsWindow = settingsWindow
        env.openSettings = { settingsWindow.show() }

        env.start()
        islands = IslandManager(env: env)
        islands.start()
        statusItem = StatusItemController(env: env, islands: islands)
        hotKey = HotKey(keyCode: kVK_ANSI_I, modifiers: cmdKey | optionKey) { [weak self] in
            self?.islands.toggleDashboard()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.stop()
    }

    /// `dynamicisland://` links, for Shortcuts and scripts:
    ///   dashboard · collapse · settings · timer?minutes=5&label=Tea · play-pause · next
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "dynamicisland" else { return }
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { $1 })
        Log.info("url command: \(command) \(query)")
        switch command {
        case "dashboard": islands.toggleDashboard()
        case "collapse": islands.controllers.values.forEach { $0.model.collapse() }
        case "settings": env.openSettings()
        case "timer":
            let minutes = Double(query["minutes"] ?? "") ?? 5
            env.timers.start(minutes: minutes, label: query["label"].flatMap { $0.isEmpty ? nil : $0 })
        case "play-pause": env.nowPlaying.togglePlayPause()
        case "next": env.nowPlaying.next()
        case "previous": env.nowPlaying.previous()
        default: Log.error("unknown url command: \(command)")
        }
    }

    /// Opening the app again from Finder or Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        env.openSettings()
        return true
    }
}
