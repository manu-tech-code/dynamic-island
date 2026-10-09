import CoreBluetooth
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
        .onAppear { env.shortcuts.loadIfNeeded() }
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

enum BluetoothText {
    static func status(_ a: CBManagerAuthorization) -> String {
        switch a {
        case .allowedAlways: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: shortcut recorder

/// Click, then press the new shortcut. Esc cancels. Needs at least one of ⌘⌥⌃.
/// There's none until one is recorded; Clear removes it.
struct HotKeyRecorder: View {
    @Environment(AppEnvironment.self) private var env
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let key = env.settings.settings.hotKey
        HStack(spacing: 8) {
            Button(recording ? "Type a shortcut…" : key?.label ?? "Record Shortcut") {
                recording ? stop() : start()
            }
            .font(key == nil || recording ? .body : .body.monospaced())
            if key != nil, !recording {
                Button("Clear") { env.settings.settings.hotKey = nil }
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
            if mods.contains(.command) { carbon |= HotKeySpec.command }
            if mods.contains(.shift) { carbon |= HotKeySpec.shift }
            if mods.contains(.option) { carbon |= HotKeySpec.option }
            if mods.contains(.control) { carbon |= HotKeySpec.control }
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
