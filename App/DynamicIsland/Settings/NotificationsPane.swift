import IslandCore
import SwiftUI

/// Settings › Notifications: messages from any app on the island. Whether,
/// how (with a live preview), which apps, and macOS's own banner.
struct NotificationsPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let messages = env.messages
        let enabled = store.settings[module: .messages].enabled
        let apps = messages.appList()
        Form {
            Section {
                MessagePreview()
            }
            Section {
                Toggle(isOn: $store.settings[module: .messages].enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show messages on the island")
                        Text("When WhatsApp, Slack, Mail, Messages, Teams or any other app gets a message, the island shows the app, who it's from and what they said.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            }
            Group {
                Section {
                    Picker("Show a message as", selection: $store.settings.messages.style) {
                        ForEach(MessageAlertStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(Self.explanation(store.settings.messages.style)).font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $store.settings.messages.holdSeconds, in: 3...15, step: 1) {
                        LabeledContent("Keep a message on the island for", value: "\(Int(store.settings.messages.holdSeconds)) s")
                    }
                    Toggle(isOn: $store.settings.messages.hideText) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide what messages say")
                            Text("Shows “New message” with who it's from, for screen sharing or a café.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Send a Test Message") { messages.show(Self.sample()) }
                        Text("Shows one on the island itself.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("How messages show")
                }
                Section {
                    Toggle(isOn: $store.settings.messages.hideSystemBanner) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide macOS's banner")
                            Text("Messages show once, on the island, for the apps switched on below: macOS's own banner is kept out of sight. They still go into Notification Center, and clicking one on the island opens its conversation. Alerts that wait for an answer come back after a few seconds.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("macOS's notifications")
                }
                Section {
                    ForEach(apps, id: \.self) { app in
                        Toggle(isOn: Binding(get: { store.settings.messages.shows(app: app) },
                                             set: { store.settings.messages.apps[app] = $0 })) {
                            HStack(spacing: 8) {
                                MessageAppIcon(app: app, bundleID: nil, size: 18)
                                Text(app)
                            }
                        }
                    }
                } header: {
                    Text("Apps · \(apps.filter { store.settings.messages.shows(app: $0) }.count) of \(apps.count) on")
                } footer: {
                    Text("Apps join this list the first time they send a notification. Music and podcast apps start off: they announce each song, which the island shows already. The island reads only what macOS shows, so each app's notification settings and Focus still apply; nothing is kept or sent anywhere.")
                }
            }
            .disabled(!enabled)
        }
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

/// The chosen style, played over your wallpaper and a notch: a sample message
/// arrives every few seconds (three at once for Stack), and a new style or
/// "Hide what messages say" replays it at once.
struct MessagePreview: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: IslandViewModel?
    @State private var availableWidth: CGFloat = 600
    @State private var loop: Task<Void, Never>?

    private static let samples = [
        MessageInfo(id: "preview-ama", app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", sender: "Ama Mensah",
                    text: "Are we still on for 6? I'll bring the charger 🔌"),
        MessageInfo(id: "preview-kofi", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", sender: "Kofi", context: "#design",
                    text: "Pushed the new icons, can you take a look before standup?"),
        MessageInfo(id: "preview-mum", app: "Messages", bundleID: "com.apple.MobileSMS", sender: "Mum", text: "Call me when you're free ❤️"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            if let model {
                PreviewCanvas(model: model, availableWidth: availableWidth, height: 160)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geo in
                            Color.clear.onAppear { availableWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, w in availableWidth = w }
                        }
                    }
            }
            Text("A sample message arrives every few seconds, the way it will on your island.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            if model == nil {
                let m = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                m.forced = .idle
                model = m
            }
            startLoop()
        }
        .onDisappear { loop?.cancel() }
        .onChange(of: env.settings.settings.messages.style) { startLoop() }
        .onChange(of: env.settings.settings.messages.hideText) { startLoop() }
    }

    /// In, held, out, and again, until the pane closes.
    private func startLoop() {
        loop?.cancel()
        loop = Task {
            var turn = 0
            while !Task.isCancelled {
                guard let model else { return }
                let style = env.settings.settings.messages.style
                let first = Self.samples[turn % Self.samples.count]
                let list = style == .stack ? [first] + Self.samples.filter { $0.id != first.id } : [first]
                withAnimation(IslandMotion.open) {
                    model.forced = .alert(IslandAlert(kind: .messages, style: .messages(list, style)))
                }
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                withAnimation(IslandMotion.close) { model.forced = .idle }
                try? await Task.sleep(for: .seconds(1.2))
                turn += 1
            }
        }
    }
}
