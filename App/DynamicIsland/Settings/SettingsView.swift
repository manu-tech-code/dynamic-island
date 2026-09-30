import IslandCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, layout, appearance, modules, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .appearance: "Appearance"
        case .modules: "Modules"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .layout: "square.grid.2x2.fill"
        case .appearance: "circle.lefthalf.filled"
        case .modules: "square.stack.3d.up.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .layout: .blue
        case .appearance: .indigo
        case .modules: .orange
        case .about: .secondary
        }
    }
}

/// System Settings-style window: sidebar of panes, grouped forms, and it
/// reopens on the pane you last viewed.
struct SettingsView: View {
    @AppStorage("settings.lastPane") private var paneRaw = SettingsPane.layout.rawValue

    var body: some View {
        let selection = Binding<SettingsPane?>(
            get: { SettingsPane(rawValue: paneRaw) ?? .layout },
            set: { if let p = $0 { paneRaw = p.rawValue } })
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.color.gradient))
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            let pane = SettingsPane(rawValue: paneRaw) ?? .layout
            Group {
                switch pane {
                case .general: GeneralPane()
                case .layout: LayoutPane()
                case .appearance: AppearancePane()
                case .modules: ModulesPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: General

private struct GeneralPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = env.settings
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
                    }
                if LaunchAtLogin.needsApproval {
                    LabeledContent("Waiting for your approval in System Settings") {
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                Toggle("Show menu bar icon", isOn: $store.settings.showMenuBarIcon)
                Picker("Show the island on", selection: $store.settings.displays) {
                    ForEach(DisplayMode.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Keyboard") {
                LabeledContent("Open or close the dashboard") { Text("⌥⌘I").monospaced() }
                LabeledContent("Island menu") { Text("Right-click the island") }
            }
            Section {
                HStack {
                    Button("Charging") { env.engine.post(IslandAlert(kind: .battery, style: .chargerConnected(percent: env.battery.info.percent))) }
                    Button("Timer done") { env.engine.post(IslandAlert(kind: .timer, style: .timerFinished(label: "Tea"), holdSeconds: 4)) }
                    Button("10-second timer") { env.timers.start(minutes: 10.0 / 60, label: "Test timer") }
                    Button("Open dashboard") { AppDelegate.shared?.islands.toggleDashboard() }
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Preview alerts and states without waiting for them to happen.")
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset all Dynamic Island settings?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { env.settings.resetToDefaults() }
                    } message: {
                        Text("Layout, appearance and module choices go back to their defaults. Timers keep running.")
                    }
            }
        }
    }
}

// MARK: Layout

private struct LayoutPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let s = store.settings
        Form {
            Section {
                Picker("Compact style", selection: $store.settings.compactStyle) {
                    ForEach(CompactStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(s.compactStyle == .beside
                     ? "Content sits in ears either side of the camera. The ears cover the menu bar icons next to the notch."
                     : "Content hangs in a band below the camera. Menu bar icons next to the notch stay visible and clickable.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Compact island")
            }

            Section {
                Toggle("No limit", isOn: Binding(
                    get: { store.settings.maxActivities == 0 },
                    set: { store.settings.maxActivities = $0 ? 0 : 3 }))
                Stepper(value: Binding(get: { max(1, store.settings.maxActivities) }, set: { store.settings.maxActivities = $0 }),
                        in: 1...IslandSettings.maxActivitiesRange.upperBound) {
                    LabeledContent("Show up to", value: s.maxActivities == 0 ? "All" : "\(s.maxActivities) at once")
                }
                .disabled(s.maxActivities == 0)
            } header: {
                Text("Live activities")
            } footer: {
                Text("The first activity takes the ears. The others appear as small icons you can click, and anything past the limit becomes a +N chip.")
            }

            Section {
                ForEach(Array(s.priority.enumerated()), id: \.element) { index, kind in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Label(kind.displayName, systemImage: kind.symbolName)
                        Spacer()
                        Button { move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(kind.displayName) up")
                        Button { move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == s.priority.count - 1).accessibilityLabel("Move \(kind.displayName) down")
                    }
                }
                .onMove { from, to in store.settings.priority.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("Priority")
            } footer: {
                Text("When several activities are live, the one highest in this list takes the island.")
            }

            Section("Opening") {
                Toggle("Open when the pointer rests on the island", isOn: $store.settings.openOnHover)
                if s.openOnHover {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: Binding(get: { Double(store.settings.hoverDelayMs) }, set: { store.settings.hoverDelayMs = Int($0) }),
                                   in: 0...800, step: 50)
                                .frame(width: 180)
                            Text("\(s.hoverDelayMs) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Toggle("Close when the pointer leaves", isOn: $store.settings.collapseOnMouseLeave)
            }
        }
    }

    private func move(_ kind: ActivityKind, by delta: Int) {
        var p = env.settings.settings.priority
        guard let i = p.firstIndex(of: kind) else { return }
        let j = i + delta
        guard p.indices.contains(j) else { return }
        p.swapAt(i, j)
        env.settings.settings.priority = p
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let material = store.settings.material
        Form {
            Section {
                Picker("Material", selection: $store.settings.material) {
                    ForEach(IslandMaterial.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Self.describe(material)).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Island")
            }
            Section {
                LabeledContent("Glass tint", value: env.look.glassTint.map { "\(Int(($0 * 100).rounded()))% toward tinted" } ?? "System default")
                LabeledContent("Reduce transparency", value: env.look.reduceTransparency ? "On" : "Off")
                LabeledContent("Increase contrast", value: env.look.increaseContrast ? "On" : "Off")
                Button("Open Appearance Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            } header: {
                Text("Liquid Glass")
            } footer: {
                Text("Hybrid and Glass use the system's own Liquid Glass, so they follow the Liquid Glass slider, Reduce Transparency and Increase Contrast in System Settings.")
            }
            Section("Now Playing") {
                Toggle("Glow from album art", isOn: $store.settings.glowFromArtwork)
            }
        }
    }

    static func describe(_ m: IslandMaterial) -> String {
        switch m {
        case .hybrid: "Black where it meets the notch, dissolving into Liquid Glass below. Seamless when compact, glass when open."
        case .glass: "Liquid Glass everywhere. The notch shows as a black block inside the glass."
        case .black: "Opaque black, like the iPhone. Ignores the Liquid Glass settings."
        }
    }
}

// MARK: Modules

private struct ModulesPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var presetsText = ""

    var body: some View {
        @Bindable var store = env.settings
        Form {
            ForEach(ActivityKind.allCases) { kind in
                Section {
                    Toggle("On", isOn: module(kind, \.enabled))
                    Toggle("Show on the compact island", isOn: module(kind, \.showInCompact))
                        .disabled(!store.settings[module: kind].enabled)
                    details(kind, store: store)
                        .disabled(!store.settings[module: kind].enabled)
                } header: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
        }
        .onAppear { presetsText = env.settings.settings.timers.presetMinutes.map(String.init).joined(separator: ", ") }
    }

    private func module(_ kind: ActivityKind, _ kp: WritableKeyPath<ModuleSettings, Bool>) -> Binding<Bool> {
        Binding(get: { env.settings.settings[module: kind][keyPath: kp] },
                set: { env.settings.settings[module: kind][keyPath: kp] = $0 })
    }

    @ViewBuilder
    private func details(_ kind: ActivityKind, store: SettingsStore) -> some View {
        @Bindable var store = store
        switch kind {
        case .nowPlaying:
            Stepper(value: $store.settings.nowPlaying.keepPausedMinutes, in: 0...30) {
                LabeledContent("Keep a paused track for", value: "\(store.settings.nowPlaying.keepPausedMinutes) min")
            }
            LabeledContent("Source", value: sourceText)
        case .timer:
            Toggle("Play a sound when a timer ends", isOn: $store.settings.timers.playSound)
            LabeledContent("Presets (minutes)") {
                TextField("1, 5, 10, 25, 60", text: $presetsText)
                    .frame(width: 180)
                    .onSubmit(savePresets)
            }
        case .calendar:
            LabeledContent("Access") {
                switch env.calendar.access {
                case .granted: Text("Allowed")
                case .notDetermined: Button("Allow Access") { env.calendar.requestAccess() }
                case .denied: Button("Open Privacy Settings") { env.calendar.openPrivacySettings() }
                }
            }
            Stepper(value: $store.settings.calendar.leadMinutes, in: 0...60, step: 5) {
                LabeledContent("Show events before they start", value: "\(store.settings.calendar.leadMinutes) min")
            }
            Toggle("Alert when an event starts", isOn: $store.settings.calendar.alertAtStart)
        case .battery:
            Toggle("Alert when the charger connects or disconnects", isOn: $store.settings.battery.alertOnPower)
            ForEach([20, 10], id: \.self) { p in
                Toggle("Alert at \(p)%", isOn: Binding(
                    get: { store.settings.battery.lowBatteryPercents.contains(p) },
                    set: { on in
                        var list = store.settings.battery.lowBatteryPercents.filter { $0 != p }
                        if on { list.append(p) }
                        store.settings.battery.lowBatteryPercents = list.sorted(by: >)
                    }))
            }
        case .backgroundApps:
            Stepper(value: $store.settings.backgroundApps.maxIcons, in: 1...24) {
                LabeledContent("Icons on the compact island", value: "\(store.settings.backgroundApps.maxIcons)")
            }
            ForEach(store.settings.backgroundApps.excludedBundleIDs, id: \.self) { id in
                LabeledContent("Hidden: \(Self.appName(id))") {
                    Button("Show") { store.settings.backgroundApps.excludedBundleIDs.removeAll { $0 == id } }
                }
            }
            Menu("Hide an App…") {
                ForEach(env.backgroundApps.apps.filter { app in
                    guard let id = app.bundleID else { return false }
                    return !store.settings.backgroundApps.excludedBundleIDs.contains(id)
                }) { app in
                    Button(app.name) { if let id = app.bundleID { store.settings.backgroundApps.excludedBundleIDs.append(id) } }
                }
            }
            .fixedSize()
        }
    }

    private var sourceText: String {
        switch env.nowPlaying.source {
        case .starting: "Starting…"
        case .bridge: "System Now Playing"
        case .appleScript: "Music and Spotify only (fallback)"
        case .unavailable: "Unavailable"
        }
    }

    private func savePresets() {
        let values = presetsText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        env.settings.settings.timers.presetMinutes = values
        env.settings.settings = env.settings.settings.normalized()
        presetsText = env.settings.settings.timers.presetMinutes.map(String.init).joined(separator: ", ")
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: About

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Section {
                Button("Show Log File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
            } footer: {
                Text("A personal build of Dynamic Island, signed with your Apple Development certificate.")
            }
        }
    }
}
