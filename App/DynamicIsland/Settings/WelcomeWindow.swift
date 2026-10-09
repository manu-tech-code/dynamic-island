import AppKit
import CoreBluetooth
import IslandCore
import SwiftUI

/// The first-run window, shown once to a new install: what the island does,
/// and the features that need macOS's permission. Each is off until it's
/// turned on here (or later in Settings), and only then does macOS ask.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(env: AppEnvironment, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Fits a 13-inch display with larger text; the list scrolls when it has to.
        let height = min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: height),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Dynamic Island"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let view = WelcomeView(done: { [weak self] in self?.window.close() }).environment(env)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [] // the window keeps its size; the list scrolls inside it
        window.contentView = host
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Continue, or the close button: either way the first run is over.
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @Environment(AppEnvironment.self) private var env
    /// Bluetooth's permission isn't observable, so it's read again while the window is open.
    @State private var bluetooth = CBManager.authorization
    private let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Turn on what you'd like").font(.headline)
                        Text("These need your permission, so they're off until you turn them on. macOS asks when you do.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        calendar
                        Divider().padding(.leading, 54)
                        devices
                        Divider().padding(.leading, 54)
                        downloads
                        Divider().padding(.leading, 54)
                        keys
                        Divider().padding(.leading, 54)
                        waveform
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 20)
            }
            Divider()
            HStack {
                Text("You can change all of this later in Settings.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                bluetooth = CBManager.authorization
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Dynamic Island").font(.title2.weight(.semibold))
                Text(intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var intro: String {
        let what = "Music, timers, downloads and alerts show on it as they happen. Click it to open it, right-click it for options, and open the dashboard for widgets."
        return hasNotch
            ? "The island lives around the notch at the top of your screen. " + what
            : "This Mac has no notch, so the island hangs from the middle of the menu bar, and only while something is on it. " + what
                + " The menu bar icon opens the dashboard any time."
    }

    // MARK: features

    private var calendar: some View {
        let on = env.settings.settings[module: .calendar].enabled
        return FeatureRow(symbol: "calendar", color: .red, title: "Calendar",
                          detail: "Your next event on the island, with a Join button for calls.",
                          isOn: module(.calendar)) {
            if on {
                switch env.calendar.access {
                case .granted: PermissionNote(text: "Allowed", allowed: true)
                case .notDetermined: PermissionNote(text: "Waiting for your answer to macOS")
                case .denied: PermissionNote(text: "Not allowed", button: "Open Settings") { env.calendar.openPrivacySettings() }
                }
            }
        }
    }

    private var devices: some View {
        let on = env.settings.settings[module: .devices].enabled
        return FeatureRow(symbol: "airpodspro", color: .indigo, title: "AirPods and Bluetooth devices",
                          detail: "An alert when they connect, with their batteries. macOS asks for Bluetooth.",
                          isOn: module(.devices)) {
            if on {
                switch bluetooth {
                case .allowedAlways: PermissionNote(text: "Allowed", allowed: true)
                case .notDetermined: PermissionNote(text: "Waiting for your answer to macOS")
                default: PermissionNote(text: "Not allowed", button: "Open Settings") { BluetoothText.openSettings() }
                }
            }
        }
    }

    private var downloads: some View {
        let on = env.settings.settings[module: .downloads].enabled
        return FeatureRow(symbol: "arrow.down.circle.fill", color: .blue, title: "Downloads",
                          detail: "Progress of downloads arriving in your Downloads folder.",
                          isOn: module(.downloads)) {
            if on { PermissionNote(text: "macOS asks for the Downloads folder when the first one finishes") }
        }
    }

    private var keys: some View {
        let hud = env.hud
        let on = env.settings.settings[module: .hud].enabled
        let isOn = Binding(
            get: { env.settings.settings[module: .hud].enabled },
            set: { new in
                env.settings.settings[module: .hud].enabled = new
                if new, !hud.accessibilityTrusted { hud.requestAccessibility() }
            })
        return FeatureRow(symbol: "speaker.wave.2.fill", color: .gray, title: "Volume and brightness",
                          detail: "The island's own HUD for the volume and brightness keys, in place of macOS's. Needs Accessibility, which messages on the island use too.",
                          isOn: isOn) {
            if on {
                if hud.accessibilityTrusted {
                    PermissionNote(text: "Allowed", allowed: true)
                } else {
                    PermissionNote(text: "Allow Dynamic Island under Accessibility", button: "Open Settings") { hud.openAccessibilitySettings() }
                }
            }
        }
    }

    private var waveform: some View {
        @Bindable var store = env.settings
        return FeatureRow(symbol: "waveform", color: .purple, title: "Waveform that follows the music",
                          detail: "The bars move with what's playing. macOS asks for System Audio Recording and shows its purple recording dot while they move. The sound is only measured, never recorded or sent.",
                          isOn: $store.settings.nowPlaying.waveformFollowsAudio) {
            if store.settings.nowPlaying.waveformFollowsAudio { PermissionNote(text: "macOS asks the first time the waveform moves") }
        }
    }

    private func module(_ kind: ActivityKind) -> Binding<Bool> {
        Binding(get: { env.settings.settings[module: kind].enabled },
                set: { env.settings.settings[module: kind].enabled = $0 })
    }
}

/// A feature in the first-run window: what it does, a switch, and where its permission stands.
private struct FeatureRow<Status: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder var status: () -> Status

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status()
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
    }
}

private struct PermissionNote: View {
    let text: String
    var allowed = false
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: allowed ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(allowed ? .green : .secondary)
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(.top, 2)
    }
}
