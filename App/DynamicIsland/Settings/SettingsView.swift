import CoreBluetooth
import IslandCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, layout, dashboard, notifications, agents, appearance, modules, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .dashboard: "Dashboard"
        case .notifications: "Notifications"
        case .agents: "AI Agents"
        case .appearance: "Appearance"
        case .modules: "Modules"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .layout: "capsule.fill"
        case .dashboard: "square.grid.2x2.fill"
        case .notifications: "bell.badge.fill"
        case .agents: "sparkles"
        case .appearance: "circle.lefthalf.filled"
        case .modules: "square.stack.3d.up.fill"
        case .permissions: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .layout: .blue
        case .dashboard: .teal
        case .notifications: .red
        case .agents: .orange
        case .appearance: .indigo
        case .modules: .orange
        case .permissions: .green
        case .about: .secondary
        }
    }
}

/// System Settings-style window: sidebar of panes, grouped forms, live
/// previews, and it reopens on the pane you last viewed.
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
                    IconBadge(symbol: pane.symbol, color: pane.color, size: 22)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            let pane = SettingsPane(rawValue: paneRaw) ?? .layout
            Group {
                switch pane {
                case .general: GeneralPane()
                case .layout: LayoutPane()
                case .dashboard: DashboardPane()
                case .notifications: NotificationsPane()
                case .agents: AgentsPane()
                case .appearance: AppearancePane()
                case .modules: ModulesPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

/// A section header with a coloured badge and a one-line description.
private struct RichHeader: View {
    let title: String
    let symbol: String
    let color: Color
    let summary: String

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
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
            Section {
                Picker("Show the island", selection: $store.settings.visibility) {
                    ForEach(IslandVisibility.allCases) { Text($0.displayName).tag($0) }
                }
                if store.settings.visibility == .onHover {
                    Picker("Animation", selection: $store.settings.revealStyle) {
                        ForEach(RevealStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("While music plays", selection: $store.settings.whilePlaying) {
                        ForEach(PlayingStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    RevealPreview()
                }
                Picker("When an app is full screen", selection: $store.settings.fullScreen) {
                    ForEach(FullScreenBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle(isOn: $store.settings.virtualNotchWhenIdle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a black notch on displays without a camera")
                        Text("Off, the middle of the menu bar stays free and clickable until something shows on the island. It's never drawn while the menu bar hides itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show the lock opening on the island when you unlock", isOn: $store.settings.lockIndicator)
            } header: {
                Text("Where it shows")
            } footer: {
                Text("“When the pointer is at the camera” keeps the island tucked under the notch until you point at the camera; “While music plays” leaves a little of it out while a song plays, and pointing at that brings the island out too. “Unless something is live” keeps music, timers, calls and downloads visible over full-screen apps, and hides the rest. Alerts always show.")
            }
            Section("Controls") {
                LabeledContent("Open or close the dashboard") { HotKeyRecorder() }
                if env.hotKeyTaken, let key = store.settings.hotKey {
                    Text("\(key.label) is already used by another app, so it doesn't work here. Record a different shortcut.")
                        .font(.callout).foregroundStyle(.orange)
                }
                LabeledContent("Open the island") { Text("Click, or scroll down on it") }
                LabeledContent("Close the island") { Text("Click outside, or scroll up") }
                LabeledContent("Island menu") { Text("Right-click the island") }
            }
            Section {
                HStack {
                    Button("Charging") { env.engine.post(IslandAlert(kind: .battery, style: .chargerConnected(percent: env.battery.info.percent))) }
                    Button("Low battery") { env.engine.post(IslandAlert(kind: .battery, style: .lowBattery(percent: 9), holdSeconds: 4)) }
                    Button("Timer done") { env.engine.post(IslandAlert(kind: .timer, style: .timerFinished(label: "Tea"), holdSeconds: 4)) }
                    Button("10-second timer") { env.timers.start(minutes: 10.0 / 60, label: "Test timer") }
                    Button("Dashboard") { AppDelegate.shared?.islands.toggleDashboard() }
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Preview alerts and states on the real island without waiting for them.")
            }
            Section("Links for Shortcuts and scripts") {
                ForEach(["dynamicisland://dashboard", "dynamicisland://timer?minutes=25&label=Focus", "dynamicisland://play-pause",
                         "dynamicisland://next", "dynamicisland://collapse"], id: \.self) { link in
                    LabeledContent(link) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset all Dynamic Island settings?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { env.settings.resetToDefaults() }
                    } message: {
                        Text("Layout, dashboard, appearance and module choices go back to their defaults. Timers keep running.")
                    }
            }
        }
    }
}

// MARK: Layout

private struct LayoutPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preview: PreviewState = .compact

    var body: some View {
        @Bindable var store = env.settings
        let s = store.settings
        Form {
            Section {
                IslandPreview(state: $preview, states: [.compact, .expanded, .alert])
            }
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
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $store.settings.openWidthScale, in: IslandSettings.widthScaleRange, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: { Text("Narrow").font(.caption) } maximumValueLabel: { Text("Wide").font(.caption) }
                            .frame(width: 260)
                        Text("\(Int((s.openWidthScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Limit the compact island's width", isOn: Binding(
                    get: { store.settings.compactMaxWidth > 0 },
                    set: { store.settings.compactMaxWidth = $0 ? 480 : 0 }))
                if s.compactMaxWidth > 0 {
                    LabeledContent("Widest") {
                        HStack {
                            Slider(value: $store.settings.compactMaxWidth, in: IslandSettings.compactMaxWidthRange, step: 10).frame(width: 260)
                            Text("\(Int(s.compactMaxWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Toggle("Show a dashboard button on the compact island", isOn: Binding(
                    get: { store.settings.dashboardButton == .always },
                    set: { store.settings.dashboardButton = $0 ? .always : .off }))
            } header: {
                Text("Size")
            } footer: {
                Text("Width applies to the open island: the dashboard, the player and the shelf. You can also drag its left or right edge. The compact island always fits what's on it, and grows or shrinks as activities come and go; whatever isn't on it is in the dashboard.")
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
                Stepper(value: $store.settings.backgroundApps.maxIcons, in: 1...24) {
                    LabeledContent("Background app icons", value: "\(s.backgroundApps.maxIcons)")
                }
            } header: {
                Text("How much it shows")
            } footer: {
                Text("The first activity takes the ears. The others appear as small icons you can click, and anything past the limit becomes a +N chip.")
            }

            Section {
                ForEach(Array(s.priority.enumerated()), id: \.element) { index, kind in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        IconBadge(symbol: kind.symbolName, color: kind.tint, size: 22)
                        Text(kind.displayName)
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
                Text("When several activities are live, the one highest in this list takes the island. Drag rows or use the arrows.")
            }

            Section("Opening and closing") {
                Toggle("Open when the pointer rests on the island", isOn: $store.settings.openOnHover)
                if s.openOnHover {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: Binding(get: { Double(store.settings.hoverDelayMs) }, set: { store.settings.hoverDelayMs = Int($0) }),
                                   in: 0...800, step: 50)
                                .frame(width: 200)
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

// MARK: Dashboard

private struct DashboardPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preview: PreviewState = .dashboard

    var body: some View {
        @Bindable var store = env.settings
        let items = store.settings.dashboard
        let rows = DashboardLayout.rows(store.settings.visibleDashboard).count
        let available = DashboardWidgetKind.allCases.filter { k in !items.contains { $0.kind == k } }
        Form {
            Section {
                IslandPreview(state: $preview, states: [.dashboard])
            }
            Section("Top bar") {
                Toggle("Show the battery percentage", isOn: $store.settings.battery.showPercent)
            }
            Section {
                if items.isEmpty {
                    Text("No widgets yet. Add some below.").foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.kind) { index, item in
                    WidgetRow(item: item, index: index, count: items.count)
                }
                .onMove { from, to in store.settings.dashboard.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("On your dashboard")
            } footer: {
                Text("Four slots per row, up to three rows. Small widgets take one slot, medium ones two. Your dashboard has \(rows) \(rows == 1 ? "row" : "rows").")
            }
            if !available.isEmpty {
                Section("Add widgets") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ForEach(available) { kind in
                            Button {
                                withAnimation { store.settings.dashboard.append(DashboardItem(kind, kind.allowedSizes.last ?? .small)) }
                            } label: {
                                HStack(spacing: 10) {
                                    IconBadge(symbol: kind.symbolName, color: kind.tint, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(kind.displayName).font(.body.weight(.semibold))
                                        Text(kind.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.title3)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section("System stats") {
                Picker("Refresh every", selection: $store.settings.systemStats.refreshSeconds) {
                    Text("½ second").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Text("CPU, GPU, memory, storage and network are only measured while the dashboard is open.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            WeatherSettingsSection()
            ClipboardSettingsSection()
            ShortcutsSettingsSection()
        }
    }
}

private struct WidgetRow: View {
    let item: DashboardItem
    let index: Int
    let count: Int
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let moduleOff = item.kind.module.map { !env.settings.settings[module: $0].enabled } ?? false
        HStack(spacing: 10) {
            IconBadge(symbol: item.kind.symbolName, color: item.kind.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                Text(moduleOff ? "Hidden: turn on \(item.kind.module!.displayName) in Modules" : item.kind.summary)
                    .font(.caption).foregroundStyle(moduleOff ? .orange : .secondary)
            }
            Spacer()
            if item.kind.allowedSizes.count > 1 {
                Picker("Size", selection: Binding(
                    get: { item.size },
                    set: { new in update { $0.size = new } })) {
                    ForEach(item.kind.allowedSizes) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            } else {
                Text("Small").font(.caption).foregroundStyle(.secondary).frame(width: 150)
            }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(item.kind.displayName) up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1).accessibilityLabel("Move \(item.kind.displayName) down")
            Button {
                withAnimation { env.settings.settings.dashboard.removeAll { $0.kind == item.kind } }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(item.kind.displayName)")
        }
    }

    private func update(_ body: (inout DashboardItem) -> Void) {
        guard let i = env.settings.settings.dashboard.firstIndex(where: { $0.kind == item.kind }) else { return }
        body(&env.settings.settings.dashboard[i])
    }

    private func move(_ delta: Int) {
        var list = env.settings.settings.dashboard
        guard let i = list.firstIndex(where: { $0.kind == item.kind }), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        withAnimation { env.settings.settings.dashboard = list }
    }
}

extension DashboardWidgetKind {
    var tint: Color {
        switch self {
        case .nowPlaying: .pink
        case .calendar: .red
        case .timer: .orange
        case .battery: .green
        case .cpu: .blue
        case .memory: .mint
        case .storage: .purple
        case .network: .cyan
        case .weather: .cyan
        case .shelf: .teal
        case .clipboard: .brown
        case .shortcuts: .pink
        case .devices: .indigo
        case .messages: .green
        case .agents: .orange
        }
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preview: PreviewState = .expanded

    var body: some View {
        @Bindable var store = env.settings
        let material = store.settings.material
        Form {
            Section {
                IslandPreview(state: $preview)
            }
            Section {
                Picker("Material", selection: $store.settings.material) {
                    ForEach(IslandMaterial.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Self.describe(material)).font(.callout).foregroundStyle(.secondary)
                Toggle("Glow from album art", isOn: $store.settings.glowFromArtwork)
            } header: {
                Text("Island")
            }
            Section {
                LabeledContent("Glass tint", value: env.look.glassTint.map { "\(Int(($0 * 100).rounded()))% toward tinted" } ?? "System default")
                LabeledContent("Reduce transparency", value: env.look.reduceTransparency ? "On" : "Off")
                LabeledContent("Increase contrast", value: env.look.increaseContrast ? "On" : "Off")
                LabeledContent("Reduce motion", value: env.look.reduceMotion ? "On" : "Off")
                Button("Open Appearance Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            } header: {
                Text("From System Settings")
            } footer: {
                Text("Hybrid and Glass use the system's own Liquid Glass, so they follow the Liquid Glass slider, Reduce Transparency and Increase Contrast. Change them in System Settings and the preview above updates.")
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
                    if kind.canBeLive {
                        Toggle("Show on the compact island", isOn: module(kind, \.showInCompact))
                            .disabled(!store.settings[module: kind].enabled)
                    }
                    details(kind, store: store)
                        .disabled(!store.settings[module: kind].enabled)
                } header: {
                    RichHeader(title: kind.displayName, symbol: kind.symbolName, color: kind.tint, summary: Self.summary(kind))
                }
            }
        }
        .onAppear { presetsText = env.settings.settings.timers.presetMinutes.map(String.init).joined(separator: ", ") }
    }

    static func summary(_ kind: ActivityKind) -> String {
        switch kind {
        case .nowPlaying: "Any app's music or video, with controls, lyrics, Up Next and output picker"
        case .timer: "Countdowns that keep running if you quit the app"
        case .calendar: "Your next event with a countdown and a Join button"
        case .battery: "Charging and low-battery moments"
        case .backgroundApps: "Apps running behind the one you're using; click to switch"
        case .shelf: "Drag files toward the notch to park them; drag them out, AirDrop or share"
        case .downloads: "Progress for downloads arriving in your Downloads folder"
        case .privacy: "Shows when an app is using your microphone or a camera"
        case .devices: "AirPods and Bluetooth devices connecting, with their batteries"
        case .hud: "A volume and brightness HUD on the island instead of the system one"
        case .messages: "New messages from WhatsApp, Slack, Mail, Messages, Teams or any app, on the island"
        case .agents: "Claude Code, Codex, OpenCode and Gemini at work, their usage, and an alert when they finish"
        }
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
            Toggle(isOn: $store.settings.nowPlaying.titleOnHover) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the title when the pointer rests on the island")
                    Text("The song and artist appear under the compact island; long titles scroll.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $store.settings.nowPlaying.titleOnTrackChange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the title when the song changes")
                    Text("The island opens for a moment with the new song and artist, then settles back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $store.settings.nowPlaying.waveformFollowsAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waveform follows the music")
                    Text("The bars move with what your Mac is playing instead of on their own. Turning this on makes macOS ask for System Audio Recording permission, and it shows its purple recording dot by Control Center while the waveform is moving. The sound is only measured, never recorded or sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Show the next track under the artist", isOn: $store.settings.nowPlaying.showUpNext)
            Toggle(isOn: $store.settings.nowPlaying.lyricsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Look up lyrics")
                    Text("When you open lyrics, the song's title, artist, album and length are sent to lrclib.net, a free lyrics database.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Source", value: sourceText)
        case .timer:
            Toggle("Play a sound when a timer ends", isOn: $store.settings.timers.playSound)
            LabeledContent("Presets (minutes)") {
                TextField("", text: $presetsText, prompt: Text("1, 5, 10, 25, 60"))
                    .labelsHidden()
                    .frame(width: 200)
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
        case .shelf: ShelfModuleSettings()
        case .downloads: Toggle("Alert when a download finishes", isOn: $store.settings.downloads.alertWhenDone)
        case .privacy:
            Toggle("Microphone", isOn: $store.settings.privacy.showMicrophone)
            Toggle("Camera", isOn: $store.settings.privacy.showCamera)
        case .devices: DevicesModuleSettings()
        case .hud: HUDModuleSettings()
        case .messages:
            // Everything about messages lives in its own pane, with a preview.
            HStack {
                Text("Styles, apps and a live preview are in Notifications.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Notifications") { UserDefaults.standard.set(SettingsPane.notifications.rawValue, forKey: "settings.lastPane") }
            }
        case .agents:
            HStack {
                Text("Agents, the dashboard card and a live preview are in AI Agents.").foregroundStyle(.secondary)
                Spacer()
                Button("Open AI Agents") { UserDefaults.standard.set(SettingsPane.agents.rawValue, forKey: "settings.lastPane") }
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
        case .bridge: "System Now Playing (any app)"
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

// MARK: Permissions

private struct PermissionsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var music = AutomationPermission.unknown
    @State private var spotify = AutomationPermission.unknown
    /// Not observable: read when the pane appears and every couple of seconds while it shows.
    @State private var bluetooth = CBManager.authorization

    var body: some View {
        let s = env.settings.settings
        Form {
            Section {
                PermissionRow(title: "Calendars", symbol: "calendar", color: .red,
                              reason: "Your next event and its Join button",
                              status: calendarStatus) {
                    switch env.calendar.access {
                    case .notDetermined:
                        Button("Allow") {
                            env.settings.settings[module: .calendar].enabled = true
                            env.calendar.requestAccess()
                        }
                    case .denied: Button("Open Settings") { env.calendar.openPrivacySettings() }
                    case .granted: EmptyView()
                    }
                }
                PermissionRow(title: "Automation · Music", symbol: "music.note", color: .pink,
                              reason: "Up Next, playing from the playlist, and AirPlay speakers",
                              status: music.label) {
                    automationButton(bundleID: MusicScripting.bundleID, status: music) { music = $0 }
                }
                PermissionRow(title: "Accessibility", symbol: "accessibility", color: .blue,
                              reason: "The volume and brightness HUD, to take over those keys, and messages on the island",
                              status: env.hud.accessibilityTrusted ? "Allowed" : "Not allowed") {
                    if !env.hud.accessibilityTrusted {
                        Button("Allow") { env.hud.requestAccessibility() }
                    }
                }
                PermissionRow(title: "Location", symbol: "location.fill", color: .cyan,
                              reason: "Weather where you are, rounded to about 1 km",
                              status: LocationText.status(env.weather.authorization)) {
                    if env.weather.authorization == .notDetermined {
                        Button("Allow") { env.settings.settings.weather.useCurrentLocation = true; env.weather.refresh() }
                    } else if env.weather.authorization == .denied {
                        Button("Open Settings") { LocationText.openSettings() }
                    }
                }
                PermissionRow(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", color: .indigo,
                              reason: "AirPods and other devices connecting, with batteries",
                              status: BluetoothText.status(bluetooth)) {
                    switch bluetooth {
                    case .notDetermined:
                        // Turning the module on is what asks.
                        if !s[module: .devices].enabled { Button("Allow") { env.settings.settings[module: .devices].enabled = true } }
                    case .denied: Button("Open Settings") { BluetoothText.openSettings() }
                    default: EmptyView()
                    }
                }
                PermissionRow(title: "Downloads folder", symbol: "arrow.down.circle.fill", color: .blue,
                              reason: "Progress of downloads arriving there",
                              status: s[module: .downloads].enabled ? "Asked when a download first finishes" : "Module off") {
                    if !s[module: .downloads].enabled { Button("Turn On") { env.settings.settings[module: .downloads].enabled = true } }
                }
                PermissionRow(title: "System Audio Recording", symbol: "waveform", color: .purple,
                              reason: "Only for the waveform following the music; macOS shows its purple dot while it listens",
                              status: s.nowPlaying.waveformFollowsAudio ? "Asked when the waveform first moves" : "Not used") {
                    if s.nowPlaying.waveformFollowsAudio {
                        Button("Open Settings") { Self.openAudioRecordingSettings() }
                    } else {
                        Button("Turn On") { env.settings.settings.nowPlaying.waveformFollowsAudio = true }
                    }
                }
                PermissionRow(title: "Automation · Spotify", symbol: "music.note.list", color: .green,
                              reason: "Fallback track info if system Now Playing is unavailable",
                              status: spotify.label) {
                    automationButton(bundleID: "com.spotify.client", status: spotify) { spotify = $0 }
                }
            } header: {
                Text("What Dynamic Island can access")
            } footer: {
                Text("macOS asks for each of these only when you turn on what needs it.")
            }
            Section("What leaves your Mac") {
                LabeledContent("Updates", value: "Once a day the app asks github.com whether there's a newer version; when there is, its release notes come from api.github.com. Turn this off in About")
                LabeledContent("Lyrics", value: "Title, artist, album and length go to lrclib.net, only when you open lyrics")
                LabeledContent("Weather", value: "Coordinates rounded to about 1 km go to open-meteo.com, only while a weather widget is on your dashboard, and so do cities you search for. Apple Maps names the place")
                LabeledContent("Clipboard", value: "Off unless you turn it on; history stays in memory and is never sent anywhere")
                LabeledContent("Everything else", value: "Stays on this Mac")
            }
        }
        .onAppear(perform: refresh)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                bluetooth = CBManager.authorization
            }
        }
    }

    static func openAudioRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private var calendarStatus: String {
        switch env.calendar.access {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        }
    }

    private func refresh() {
        music = AutomationPermission.status(for: MusicScripting.bundleID)
        spotify = AutomationPermission.status(for: "com.spotify.client")
        bluetooth = CBManager.authorization
    }

    @ViewBuilder
    private func automationButton(bundleID: String, status: AutomationPermission, update: @escaping (AutomationPermission) -> Void) -> some View {
        switch status {
        case .notDetermined:
            Button("Allow") { Task { update(await AutomationPermission.request(for: bundleID)) } }
        case .denied:
            Button("Open Settings") { AutomationPermission.openSettings() }
        case .appNotRunning, .unknown:
            Button("Check Again") { refresh() }
        case .granted:
            EmptyView()
        }
    }
}

private struct PermissionRow<Action: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let reason: String
    let status: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).foregroundStyle(status == "Allowed" ? .green : .secondary)
            action()
        }
    }
}

// MARK: About

private struct AboutPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var automatic = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamic Island").font(.title3.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { _, on in env.updates.automaticallyChecks = on }
                LabeledContent("Last checked", value: env.updates.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                Button(env.updates.available.map { "Install Update \($0)…" } ?? "Check for Updates…") { env.updates.checkForUpdates() }
            } header: {
                Text("Updates")
            } footer: {
                Text("Once a day, Dynamic Island checks for the latest update.")
            }
            .onAppear { automatic = env.updates.automaticallyChecks }
        }
    }
}
