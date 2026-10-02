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
        // Opening Settings from anywhere (the dashboard's gear, Add Widgets…, a menu,
        // a link) closes the island first, so it doesn't sit over the window.
        env.openSettings = { [weak self] in
            self?.islands?.collapseAll()
            settingsWindow.show()
        }

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
        case "check-for-updates": env.updates.checkForUpdates()
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
        case "debug-update-window":
            // dynamicisland://debug-update-window?phase=found|checking|downloading|installing|uptodate|error&version=0.8.0
            let phases: [String: UpdateFlow.Phase] = ["found": .found, "checking": .checking, "downloading": .downloading(0.42),
                                                     "installing": .installing(nil), "uptodate": .upToDate,
                                                     "error": .failed("The download didn't match its signature.")]
            env.updates.debugWindow(phases[query["phase"] ?? "found"] ?? .found, version: query["version"] ?? "0.8.0")
            if let name = query["render"] {
                // Once the notes are in, the window's content drawn offline (light and dark).
                Task { [env] in
                    try? await Task.sleep(for: .seconds(3))
                    for scheme in [ColorScheme.light, .dark] {
                        let actions = UpdateActions(updateNow: {}, later: {}, skip: {}, cancel: {}, done: {}, viewOnGitHub: {}, closed: {})
                        let view = UpdateWindowView(flow: env.updates.debugFlow, actions: actions, scrolls: false)
                            .frame(width: 760, height: 540).environment(\.colorScheme, scheme)
                        let r = ImageRenderer(content: view)
                        r.scale = 2
                        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            let file = "update-\(name)-\(scheme == .dark ? "dark" : "light").png"
                            try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent(file))
                            Log.info("rendered \(file)")
                        }
                    }
                }
            }
        case "debug-update-press":
            // dynamicisland://debug-update-press?button=update|later|skip|cancel|ok|close
            env.updates.debugPress(query["button"] ?? "")
        case "debug-update-background":
            // The daily check, now: a newer version should end up on the island.
            env.updates.debugBackgroundCheck()
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
        case "debug-render-widget":
            // dynamicisland://debug-render-widget?kind=cpu&size=medium — one dashboard card, offline, on black.
            guard let kind = query["kind"].flatMap(DashboardWidgetKind.init(rawValue:)) else { break }
            let size = query["size"].flatMap(WidgetSize.init(rawValue:)) ?? .small
            let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
            let width = DashboardView.width(size)
            let card = WidgetView(item: DashboardItem(kind, size), radius: 16, model: model)
                .frame(width: width, height: DashboardLayout.cardHeight)
                .padding(14).background(.black).environment(\.colorScheme, .dark).environment(env)
            let r = ImageRenderer(content: card)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("widget-\(kind.rawValue)-\(size.rawValue).png"))
                Log.info("rendered widget \(kind.rawValue) \(size.rawValue) \(Int(width))×\(Int(DashboardLayout.cardHeight))")
            }
        case "debug-visibility":
            // dynamicisland://debug-visibility?mode=onHover|always&style=slide&playing=bubble&reveal=1|0&announce=1
            if let mode = query["mode"].flatMap(IslandVisibility.init(rawValue:)) { env.settings.settings.visibility = mode }
            if let style = query["style"].flatMap(RevealStyle.init(rawValue:)) { env.settings.settings.revealStyle = style }
            if let playing = query["playing"].flatMap(PlayingStyle.init(rawValue:)) { env.settings.settings.whilePlaying = playing }
            if let reveal = query["reveal"] { islands.controllers.values.forEach { $0.model.setRevealed(reveal == "1") } }
            if query["announce"] == "1" { islands.controllers.values.forEach { $0.model.announceTrack() } }
            for c in islands.controllers.values {
                Log.info("visibility \(c.model.settings.visibility.rawValue)/\(c.model.settings.revealStyle.rawValue), playing \(c.model.settings.whilePlaying.rawValue) \(c.model.indicatorPhase), revealed \(c.model.revealed), announcing \(c.model.announcing), tucked \(c.model.isTucked): \(c.model.contentKey) \(Int(c.model.outerSize.width))×\(Int(c.model.outerSize.height))")
                if let name = query["render"] {
                    // The live island, drawn offline over the wallpaper (glass shows as a placeholder).
                    let r = ImageRenderer(content: PreviewCanvas(model: c.model, availableWidth: 760).environment(env))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("vis-\(name).png"))
                    }
                }
            }
        case "debug-ax-banner":
            if query["windows"] != nil { Log.info("ax windows: " + AXDump.windows()) }
            else if query["actions"] != nil { Log.info("ax actions:\n" + AXDump.bannerActions()) }
            else if query["anatomy"] != nil { Log.info("ax anatomy:\n" + AXDump.bannerAnatomy()) }
            else if query["settable"] != nil { Log.info("ax settable:\n" + AXDump.settable()) }
            else if query["bannertree"] != nil { Log.info("ax banner tree:\n" + AXDump.notificationCenter()) }
            else if let y = query["move"] { Log.info("ax move: " + AXDump.moveBannerWindow(y: y == "where" ? nil : CGFloat(Double(y) ?? 0))) }
            else if let name = query["perform"] { Log.info("ax perform " + AXDump.perform(name)) }
            else if let text = query["history"] { Task { Log.info("ax history: " + (await AXDump.historyContains(text))) } }
            else if let text = query["clear"] { Task { Log.info("ax clear: " + (await AXDump.historyContains(text, clearing: true))) } }
            else { Log.info("ax banner:\n" + AXDump.notificationCenter()) }
        case "debug-audio":
            // What the waveform hears: the tap, and the bars' latest heights.
            Log.info("audio levels: \(env.audioLevels.debugDescription)")
        case "debug-layers":
            // The Core Animation views on screen: where they are, and whether they're moving.
            func walk(_ v: NSView, in w: NSWindow) {
                if v is WaveformLayerView || v is AnimatedImageView {
                    let f = v.convert(v.bounds, to: nil)
                    let moving = (v.layer?.sublayers ?? []).flatMap { $0.animationKeys() ?? [] }
                    let bars = (v.layer?.sublayers ?? []).map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: " ")
                    let color = (v.layer?.sublayers?.first?.backgroundColor).map { "\($0.components ?? [])" } ?? "-"
                    Log.info("layers: \(type(of: v)) at \(Int(f.minX)),\(Int(w.frame.height - f.maxY)) \(Int(f.width))×\(Int(f.height)) alpha \(v.alphaValue) hidden \(v.isHiddenOrHasHiddenAncestor) moving \(moving) [\(bars)] colour \(color)")
                }
                v.subviews.forEach { walk($0, in: w) }
            }
            for w in NSApp.windows where w.isVisible { if let v = w.contentView { walk(v, in: w) } }
        case "debug-render-goo":
            // The bubbles and the drop at a few points of coming out of the notch.
            let r = ImageRenderer(content: PlayingIndicatorFrames())
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("goo-frames.png"))
                Log.info("rendered goo-frames.png")
            }
        case "debug-reveal-preview":
            // The Settings reveal preview's island, out and tucked, rendered offline.
            let m = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
            m.forced = .compact
            for (name, tucked) in [("out", false), ("tucked", true)] {
                m.setPreviewTuck(tucked)
                let r = ImageRenderer(content: PreviewCanvas(model: m, availableWidth: 760, height: 96).environment(env))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("reveal-preview-\(name).png"))
                    Log.info("reveal preview \(name): tucked \(m.isTucked) \(m.contentKey) \(Int(m.outerSize.width))×\(Int(m.outerSize.height)) style \(m.revealStyle?.rawValue ?? "-")")
                }
            }
        case "debug-lock":
            // Plays the lock, then the unlock, without locking the Mac.
            env.lock.debugSimulate(seconds: 3)
        case "debug-render-alerts":
            // Compact alerts in both styles, with a device's details open.
            let pods = BluetoothDeviceInfo(id: "p", name: "Emmanuel’s AirPods Pro", kind: .airpodsPro,
                                           batteryLeft: 82, batteryRight: 64, batteryCase: 45)
            let styles: [(String, IslandAlert.Style, Bool)] = [
                ("airpods", .deviceConnected(pods), false), ("airpods-hover", .deviceConnected(pods), true),
                ("oraimo", .deviceConnected(BluetoothDeviceInfo(id: "o", name: "oraimo SpaceBuds", kind: .earbuds,
                                                                 batteryLeft: 70, batteryRight: 18)), true),
                ("charger", .chargerConnected(percent: 100), false), ("low", .lowBattery(percent: 9), false),
                ("disconnected", .deviceDisconnected(name: "AirPods Pro", kind: .airpodsPro), false)]
            let saved = env.settings.settings.compactStyle
            for style in CompactStyle.allCases {
                env.settings.settings.compactStyle = style
                for (name, alertStyle, hover) in styles {
                    let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                    model.debugPresentation = .alert(IslandAlert(kind: .devices, style: alertStyle))
                    model.debugPeek(hover: hover, peek: hover)
                    let r = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 760).environment(env))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        let file = "alert-\(style.rawValue)-\(name).png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent(file))
                        Log.info("render \(file) outer \(model.outerSize)")
                    }
                }
            }
            env.settings.settings.compactStyle = saved
        case "debug-render-badge":
            let badge = HStack(spacing: 14) {
                UnreadBadgeIcon(app: UnreadApp(app: "Messages", bundleID: "com.apple.MobileSMS", count: 3, lastSender: "Mum"))
                Phase2Glyph(payload: .messages([UnreadApp(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", count: 12, lastSender: "Kofi")]))
            }
            .padding(14).background(.black).environment(\.colorScheme, .dark).environment(env)
            let r = ImageRenderer(content: badge)
            r.scale = 3
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("badge.png"))
            }
        case "debug-message-open":
            // Opens the latest message, as clicking it on the island does.
            if let m = env.messages.lastMessage { env.messages.open(m) } else { Log.info("messages: nothing to open") }
        case "debug-message-style":
            // dynamicisland://debug-message-style?style=card|ears|ticker|stack|badges&forget=<app>
            if let style = query["style"].flatMap(MessageAlertStyle.init(rawValue:)) { env.settings.settings.messages.style = style }
            if let app = query["forget"] { env.settings.settings.messages.apps[app] = nil }
            if let hide = query["hide"] { env.settings.settings.messages.hideSystemBanner = hide == "1" }
            if let app = query["off"] { env.settings.settings.messages.apps[app] = false }
            if let app = query["on"] { env.settings.settings.messages.apps[app] = true }
            Log.info("messages: style \(env.settings.settings.messages.style.rawValue), unread \(env.messages.unread.map { "\($0.app) \($0.count)" }), apps \(env.messages.appList().map { "\($0) \(env.settings.settings.messages.shows(app: $0) ? "on" : "off")" })")
        case "debug-render-messages":
            // Each message style, and their hover states, beside the notch.
            let ama = MessageInfo(id: "a", app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", sender: "Ama Mensah", text: "Are we still on for 6? I'll bring the charger 🔌")
            let kofi = MessageInfo(id: "k", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", sender: "Kofi", context: "#design", text: "Pushed the new icons, can you take a look before standup?")
            let mum = MessageInfo(id: "m", app: "Messages", bundleID: "com.apple.MobileSMS", sender: "Mum", text: "Call me when you're free ❤️")
            let cases: [(String, [MessageInfo], MessageAlertStyle, Bool)] = [
                ("card", [ama], .card, false), ("ears", [ama], .ears, false), ("ears-hover", [ama], .ears, true),
                ("ticker", [kofi], .ticker, false), ("stack", [mum, kofi, ama], .stack, false), ("stack-hover", [mum, kofi, ama], .stack, true),
                ("badges", [ama], .badges, false)]
            for (name, list, style, hover) in cases {
                let model = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                model.debugPresentation = .alert(IslandAlert(kind: .messages, style: .messages(list, style)))
                model.debugPeek(hover: hover, peek: hover)
                let r = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 760).environment(env))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent("message-\(name).png"))
                    Log.info("render message-\(name) outer \(model.outerSize)")
                }
            }
        case "debug-media-rects":
            // Where each island thinks the playing track is, next to the island's own outline.
            for (id, c) in islands.controllers {
                let rects = c.model.mediaRects.map { "\($0.key) \(Int($0.value.minX)),\(Int($0.value.minY)) \(Int($0.value.width))×\(Int($0.value.height))" }
                Log.info("island \(id): \(c.model.contentKey) outline \(c.islandRect) media \(rects.sorted())")
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
                for (state, hover, on) in [("rest", false, false), ("hover", true, false), ("on", true, true)] {
                    model.debugPeek(hover: hover, peek: on)
                    let r = ImageRenderer(content: PreviewCanvas(model: model, availableWidth: 760).environment(env))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        let name = "peek\(i)-\(style.rawValue)-\(state).png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: Log.fileURL.deletingLastPathComponent().appendingPathComponent(name))
                        Log.info("render \(name) ears L\(model.compactFit.ears.leading) R\(model.compactFit.ears.trailing) outer \(model.outerSize) radius \(model.radius) collar \(model.collarHeight) track \(model.peekingTrack?.title ?? "none") primary \(model.compactFit.ranked.primary?.kind.rawValue ?? "-") visible \(model.compactFit.ranked.visible.map(\.kind.rawValue))")
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
