import CoreLocation
import IslandCore
import SwiftUI

// MARK: module details

struct ShelfModuleSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        Toggle("Open the shelf when you drag something toward the notch", isOn: $store.settings.shelf.openOnDrag)
        if store.settings.shelf.openOnDrag {
            LabeledContent("How close to the top") {
                HStack {
                    Slider(value: $store.settings.shelf.dragActivationDistance, in: 20...300, step: 10).frame(width: 180)
                    Text("\(Int(store.settings.shelf.dragActivationDistance)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
        }
        LabeledContent("On the shelf now", value: "\(env.shelf.items.count) \(env.shelf.items.count == 1 ? "item" : "items")")
        HStack {
            Button("Open Shelf") { AppDelegate.shared?.islands.primary?.model.openShelf() }
            Button("Clear Shelf", role: .destructive) { env.shelf.clear() }.disabled(env.shelf.items.isEmpty)
        }
        Text("Files stay where they are; the shelf only keeps a reference. Text, links and images you drop are saved in Application Support.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct DevicesModuleSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        Toggle("Alert when a device connects", isOn: $store.settings.devices.alertOnConnect)
        Toggle("Alert when headphones or speakers disconnect", isOn: $store.settings.devices.alertOnDisconnect)
        if env.devices.connected.isEmpty {
            LabeledContent("Connected", value: "None")
        } else {
            ForEach(env.devices.connected) { d in
                LabeledContent {
                    Text(Self.batteryText(d)).foregroundStyle(.secondary)
                } label: {
                    Label(d.name, systemImage: d.kind.symbolName)
                }
            }
        }
    }

    static func batteryText(_ d: BluetoothDeviceInfo) -> String {
        var parts: [String] = []
        if let l = d.batteryLeft { parts.append("L \(l)%") }
        if let r = d.batteryRight { parts.append("R \(r)%") }
        if let c = d.batteryCase { parts.append("Case \(c)%") }
        if parts.isEmpty, let b = d.battery { parts.append("\(b)%") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: "  ")
    }
}

struct HUDModuleSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let hud = env.hud
        Toggle(isOn: $store.settings.hud.replaceSystemHUD) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace the system HUD")
                Text("Takes over the volume, mute and brightness keys so only the island shows. Needs Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if store.settings.hud.replaceSystemHUD {
            LabeledContent("Keys") {
                switch hud.tapState {
                case .active: Text("Handled by Dynamic Island").foregroundStyle(.green)
                case .needsPermission:
                    HStack {
                        Text("Needs Accessibility").foregroundStyle(.orange)
                        Button("Allow…") { hud.requestAccessibility() }
                        Button("Open Settings") { hud.openAccessibilitySettings() }
                    }
                case .failed: Text("Couldn't take over the keys").foregroundStyle(.red)
                case .off: Text("Off").foregroundStyle(.secondary)
                }
            }
        } else {
            Text("The island shows a HUD when the volume changes; macOS shows its own too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Volume", isOn: $store.settings.hud.showVolume)
        Toggle("Brightness", isOn: $store.settings.hud.showBrightness)
        Picker("Steps per key press", selection: $store.settings.hud.steps) {
            Text("16 (like macOS)").tag(16)
            Text("32").tag(32)
            Text("64").tag(64)
        }
        Text("Hold ⌥⇧ while pressing a key for quarter steps, as in macOS.").font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: widget settings (Dashboard pane)

struct WeatherSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results: [OpenMeteo.Place] = []
    @State private var searching = false

    var body: some View {
        @Bindable var store = env.settings
        let weather = env.weather
        Section {
            Toggle("Use my current location", isOn: $store.settings.weather.useCurrentLocation)
                .onChange(of: store.settings.weather.useCurrentLocation) { weather.refresh() }
            if store.settings.weather.useCurrentLocation {
                LabeledContent("Location access", value: LocationText.status(weather.authorization))
            }
            LabeledContent("Place") {
                Text(weather.placeName ?? store.settings.weather.placeName ?? "Not set").foregroundStyle(.secondary)
            }
            HStack {
                TextField("", text: $query, prompt: Text("Search for a city"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searching { ProgressView().controlSize(.small) }
            }
            ForEach(results) { place in
                Button { weather.choose(place); results = []; query = "" } label: {
                    Label(place.label, systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.borderless)
            }
            Picker("Temperature", selection: $store.settings.weather.unit) {
                ForEach(TemperatureUnit.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: store.settings.weather.unit) { weather.refresh() }
        } header: {
            Text("Weather")
        } footer: {
            Text("Forecasts come from Open-Meteo. Your coordinates are rounded to about 1 km and only sent while a Weather widget is on your dashboard.")
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = await env.weather.search(q)
            searching = false
        }
    }
}

struct ClipboardSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        Section {
            Toggle(isOn: $store.settings.clipboard.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep clipboard history")
                    Text("Watches what you copy while this is on. History stays in memory and is cleared when you quit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.settings.clipboard.enabled {
                Stepper(value: $store.settings.clipboard.historySize, in: 5...100, step: 5) {
                    LabeledContent("Keep the last", value: "\(store.settings.clipboard.historySize) items")
                }
                Toggle("Skip passwords and other concealed items", isOn: $store.settings.clipboard.ignoreConcealed)
                if env.clipboard.accessBehavior == .alwaysDeny {
                    Text("macOS is blocking clipboard access for Dynamic Island. Allow it in System Settings › Privacy & Security › Paste from Other Apps.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Clear History", role: .destructive) { env.clipboard.clear() }.disabled(env.clipboard.entries.isEmpty)
            }
        } header: {
            Text("Clipboard")
        }
    }
}

struct ShortcutsSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let pinned = store.settings.shortcuts.pinned
        Section {
            if pinned.isEmpty {
                Text("No shortcuts pinned yet.").foregroundStyle(.secondary)
            }
            ForEach(pinned, id: \.self) { name in
                LabeledContent(name) {
                    Button { store.settings.shortcuts.pinned.removeAll { $0 == name } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Unpin \(name)")
                }
            }
            HStack {
                Menu("Pin a Shortcut…") {
                    ForEach(env.shortcuts.all.filter { !pinned.contains($0) }, id: \.self) { name in
                        Button(name) { store.settings.shortcuts.pinned.append(name) }
                    }
                }
                .fixedSize()
                .disabled(env.shortcuts.all.isEmpty)
                Button("Reload") { env.shortcuts.reload() }
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text(env.shortcuts.all.isEmpty ? "No shortcuts found. Make some in the Shortcuts app." : "\(env.shortcuts.all.count) shortcuts available.")
        }
    }
}

enum LocationText {
    static func status(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways, .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: shortcut recorder

/// Click, then press the new shortcut. Esc cancels. Needs at least one of ⌘⌥⌃.
struct HotKeyRecorder: View {
    @Environment(AppEnvironment.self) private var env
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Type a shortcut…" : env.settings.settings.hotKey.label) {
                recording ? stop() : start()
            }
            .font(.body.monospaced())
            if env.settings.settings.hotKey != .default {
                Button("Reset") { env.settings.settings.hotKey = .default }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            var carbon = 0
            if mods.contains(.command) { carbon |= 256 }
            if mods.contains(.shift) { carbon |= 512 }
            if mods.contains(.option) { carbon |= 2048 }
            if mods.contains(.control) { carbon |= 4096 }
            let label = Self.symbols(mods) + Self.keyName(event)
            env.settings.settings.hotKey = HotKeySpec(keyCode: Int(event.keyCode), carbonModifiers: carbon, label: label)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    static func symbols(_ m: NSEvent.ModifierFlags) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }

    static func keyName(_ e: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let s = special[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Settings › Modules › Messages: how a message shows, what it says, and the
/// permission reading the banners needs.
struct MessagesModuleSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let messages = env.messages
        let apps = messages.appList()
        Picker("Show a message as", selection: $store.settings.messages.style) {
            ForEach(MessageAlertStyle.allCases) { Text($0.displayName).tag($0) }
        }
        Text(Self.explanation(store.settings.messages.style)).font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Send a Test Message") { messages.show(Self.sample()) }
            Text("Shows one in the style above.").font(.caption).foregroundStyle(.secondary)
        }
        Toggle(isOn: $store.settings.messages.hideText) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide what messages say")
                Text("Shows “New message” with who it's from, for screen sharing or a café.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle(isOn: $store.settings.messages.hideSystemBanner) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide macOS's banner")
                Text("Messages show once, on the island, for the apps switched on below: macOS's own banner is kept out of sight instead. They still go into Notification Center's list, and Open goes straight to the conversation. Alerts that wait for an answer come back after a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Stepper(value: $store.settings.messages.holdSeconds, in: 3...15, step: 1) {
            LabeledContent("Keep a message on the island for", value: "\(Int(store.settings.messages.holdSeconds)) s")
        }
        // Which apps: one switch each.
        LabeledContent("Apps") { Text("\(apps.filter { store.settings.messages.shows(app: $0) }.count) of \(apps.count) on").foregroundStyle(.secondary) }
        ForEach(apps, id: \.self) { app in
            Toggle(isOn: Binding(get: { store.settings.messages.shows(app: app) },
                                 set: { store.settings.messages.apps[app] = $0 })) {
                HStack(spacing: 8) {
                    MessageAppIcon(app: app, bundleID: nil, size: 18)
                    Text(app)
                }
            }
            .padding(.leading, 12)
        }
        Text("Apps join this list the first time they send a notification. Music and podcast apps start off: they announce each song, which the island shows already.")
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Reading notifications") {
            if messages.trusted {
                Text("Allowed").foregroundStyle(.green)
            } else {
                HStack {
                    Text("Needs Accessibility").foregroundStyle(.orange)
                    Button("Allow…") { messages.requestAccessibility() }
                }
            }
        }
        Text("The island reads the banners macOS shows, so each app's notification settings and Focus still apply. Nothing is kept or sent anywhere.")
            .font(.caption).foregroundStyle(.secondary)
    }

    static func explanation(_ style: MessageAlertStyle) -> String {
        switch style {
        case .card: "The island opens into a card: the app, who it's from, the first two lines, and Open."
        case .ears: "The app's icon and the sender beside the camera; point at it for the message."
        case .ticker: "One line: the sender, and the message scrolling past."
        case .stack: "Messages that arrive together pile up, newest on top; point at the stack for the list."
        case .badges: "Like ears, then the app's icon stays with an unread count until you open the app."
        }
    }

    static func sample() -> MessageInfo {
        MessageInfo(id: UUID().uuidString, app: "Messages", bundleID: "com.apple.MobileSMS", sender: "Dynamic Island",
                    text: "This is how a message looks on the island. Point at it to keep it here.")
    }
}
