import AppKit
import Carbon.HIToolbox
import IslandCore
import SwiftUI

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
        registerHotKey(env.settings.settings.hotKey)
        whenChanged({ [env] in env.settings.settings.hotKey }) { [weak self] spec in self?.registerHotKey(spec) }
        showWelcomeIfFirstLaunch()
    }

    private func registerHotKey(_ spec: HotKeySpec) {
        hotKey = nil
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.carbonModifiers) { [weak self] in
            self?.islands.toggleDashboard()
        }
        Log.info("hotkey \(spec.label) \(hotKey == nil ? "failed" : "registered")")
    }

    /// A one-time tip, so the dashboard button and right-click are discoverable.
    private func showWelcomeIfFirstLaunch() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { [env] in
            try? await Task.sleep(for: .seconds(1.5))
            env.engine.post(IslandAlert(kind: .backgroundApps, style: .message(
                title: "Dynamic Island is ready",
                subtitle: "Click it to open. The grid button opens the dashboard; right-click for options.",
                symbol: "sparkles"), holdSeconds: 7))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.stop()
    }

    /// `dynamicisland://` links, for Shortcuts and scripts:
    ///   dashboard · shelf · collapse · settings · timer?minutes=5&label=Tea · play-pause · next · lyrics · up-next
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
        case "shelf": islands.primary?.model.openShelf()
        case "lyrics": islands.primary?.showNowPlaying(page: .lyrics)
        case "up-next": islands.primary?.showNowPlaying(page: .upNext)
        case "play-pause": env.nowPlaying.togglePlayPause()
        case "next": env.nowPlaying.next()
        case "previous": env.nowPlaying.previous()
        #if DEBUG
        case "debug-check":
            // Exercises lyrics and Up Next on whatever is loaded, even if paused.
            if let info = env.nowPlaying.info { env.lyrics.load(for: info) }
            env.nowPlaying.refreshQueue()
            env.audioOutput.refresh()
            Log.info("outputs: \(env.audioOutput.devices.map { "\($0.name)\($0.id == env.audioOutput.defaultID ? "*" : "")" }) volume \(env.audioOutput.volume.map { String(format: "%.2f", $0) } ?? "n/a")")
            Task { Log.info("music airplay: \(await MusicScripting.airPlayDevices().map { "\($0.name)\($0.selected ? "*" : "")" })") }
        case "debug-snapshot":
            // Renders our own windows to PNGs in the log folder (no screen capture involved).
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = Log.fileURL.deletingLastPathComponent().appendingPathComponent("window-\(i)-\(w.title.isEmpty ? "panel" : "settings").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                Log.info("snapshot \(url.lastPathComponent) \(Int(view.bounds.width))×\(Int(view.bounds.height))")
            }
        case "debug-render":
            // Offline SwiftUI render of the preview canvas (glass doesn't render; layout does).
            let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
            for (name, p) in [("compact", IslandPresentation.compact), ("expanded", .expanded(activityID: "")), ("dashboard", .dashboard)] {
                model.forced = p
                let renderer = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 680).environment(env))
                renderer.scale = 1
                if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    let url = Log.fileURL.deletingLastPathComponent().appendingPathComponent("render-\(name).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    Log.info("render \(name) \(Int(img.size.width))×\(Int(img.size.height)) outer \(model.outerSize)")
                }
            }
        case "debug-render-peek":
            // The compact island with the title under it, both styles; the live track must be primary.
            let saved = env.settings.settings.compactStyle
            let samples = [NowPlayingInfo(title: "Emagination (B - Side)", artist: "Amtrac", isPlaying: true),
                           NowPlayingInfo(title: "A Much Longer Title That Cannot Possibly Fit Under The Ears (Extended Mix)",
                                          artist: "Somebody feat. Somebody Else", isPlaying: true)]
            let savedTrack = env.nowPlaying.debugSwapInfo(samples[0])
            defer { _ = env.nowPlaying.debugSwapInfo(savedTrack) }
            for (i, sample) in samples.enumerated() {
            _ = env.nowPlaying.debugSwapInfo(sample)
            for style in CompactStyle.allCases {
                env.settings.settings.compactStyle = style
                let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                for on in [false, true] {
                    model.debugPeek(on)
                    let r = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 760).environment(env))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        let name = "peek\(i)-\(style.rawValue)-\(on ? "on" : "off").png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent(name))
                        Log.info("render \(name) outer \(model.outerSize) radius \(model.radius) collar \(model.collarHeight) track \(model.peekingTrack?.title ?? "none") primary \(model.compactFit.ranked.primary?.kind.rawValue ?? "-") visible \(model.compactFit.ranked.visible.map(\.kind.rawValue))")
                    }
                }
            }
            }
            env.settings.settings.compactStyle = saved
        case "debug-phase2":
            Log.info("shortcuts: \(env.shortcuts.all.count) available")
            Log.info("devices: \(env.devices.connected.map { "\($0.name) [\($0.kind)] \(DevicesModuleSettings.batteryText($0))" })")
            Log.info("privacy: mic \(env.privacy.microphone) camera \(env.privacy.camera)")
            Log.info("clipboard access: \(env.clipboard.accessBehavior.rawValue), brightness \(Brightness.get().map { String(format: "%.2f", $0) } ?? "n/a"), AX \(env.hud.accessibilityTrusted)")
            Task {
                // Apple Park, so no location prompt is needed for the check.
                if let url = OpenMeteo.forecastURL(latitude: 37.33, longitude: -122.01, fahrenheit: true),
                   let (data, _) = try? await URLSession.shared.data(from: url), let r = OpenMeteo.parseForecast(data) {
                    Log.info("weather check: \(Int(r.temperature))° \(r.condition.summary) H\(r.high.map { Int($0) } ?? 0) hours \(r.hours.count)")
                } else { Log.error("weather check failed") }
            }
        case "debug-render-widths":
            // The island at three widths, rendered offline, to check nothing is cut off.
            let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
            for scale in [0.75, 1.0, 1.35] {
                model.liveWidthScale = scale
                for (name, p) in [("compact", IslandPresentation.compact), ("expanded", .expanded(activityID: "")), ("dashboard", .dashboard)] {
                    model.forced = p
                    let r = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 900).environment(env))
                    r.scale = 1
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        let url = Log.fileURL.deletingLastPathComponent().appendingPathComponent("width-\(name)-\(Int(scale * 100)).png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                    Log.info("width \(Int(scale * 100))% \(name): \(Int(model.outerSize.width))×\(Int(model.outerSize.height))")
                }
            }
        case "debug-render-widgets":
            let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
            let slot = DashboardLayout.slotWidth(forWidth: DashboardLayout.width)
            func save(_ view: some View, _ name: String) {
                let r = ImageRenderer(content: view.environment(env).environment(\.colorScheme, .dark))
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("render-\(name).png"))
                }
            }
            let kinds: [DashboardWidgetKind] = [.weather, .shelf, .clipboard, .shortcuts, .devices]
            let grid = VStack(alignment: .leading, spacing: 10) {
                ForEach(kinds) { k in
                    HStack(spacing: 10) {
                        WidgetView(item: DashboardItem(k, .small), radius: 22, model: model).frame(width: slot, height: DashboardLayout.cardHeight)
                        WidgetView(item: DashboardItem(k, .medium), radius: 22, model: model).frame(width: DashboardView.width(.medium), height: DashboardLayout.cardHeight)
                    }
                }
            }.padding(14).background(Color(white: 0.12))
            save(grid, "widgets")
            model.forced = .shelf
            save(ShelfView(model: model).frame(width: 612, height: 216).background(Color(white: 0.12)), "shelf")
            model.forced = .alert(IslandAlert(kind: .hud, style: .volume(level: 0.6, muted: false, output: "Speakers")))
            save(IslandRootView(model: model).frame(width: 760, height: 120).background(Color(white: 0.3)), "hud")
            Log.info("rendered widgets, shelf and hud")
        case "debug-music":
            let probes = ["player state", "class of current track", "index of current track", "name of container of current track",
                          "class of container of current track", "count of tracks of container of current track",
                          "name of current playlist", "shuffle enabled", "song repeat"]
            Task {
                for probe in probes {
                    let out = await MusicScripting.run("tell application id \"com.apple.Music\" to get \(probe)")
                    Log.info("music probe [\(probe)] → \(out ?? "error")")
                }
            }
        #endif
        default: Log.error("unknown url command: \(command)")
        }
    }

    /// Opening the app again from Finder or Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        env.openSettings()
        return true
    }
}
