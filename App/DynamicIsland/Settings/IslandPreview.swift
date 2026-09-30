import AppKit
import IslandCore
import SwiftUI

enum PreviewState: String, CaseIterable, Identifiable {
    case compact, expanded, dashboard, alert
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .expanded: "Expanded"
        case .dashboard: "Dashboard"
        case .alert: "Alert"
        }
    }
}

/// The real island views, live data and all, drawn over your wallpaper with
/// a virtual notch. Updates as you change settings.
struct IslandPreview: View {
    @Binding var state: PreviewState
    var states: [PreviewState] = PreviewState.allCases
    @Environment(AppEnvironment.self) private var env
    @State private var model: IslandViewModel?
    @State private var availableWidth: CGFloat = 680
    @State private var sampleAlert = IslandAlert(kind: .battery, style: .chargerConnected(percent: 80), holdSeconds: 0)

    var body: some View {
        VStack(spacing: 10) {
            if states.count > 1 {
                Picker("Preview", selection: $state) {
                    ForEach(states) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }
            if let model {
                canvas(model)
            }
            if env.engine.ranked.isEmpty, state != .dashboard, state != .alert {
                HStack(spacing: 8) {
                    Text("Nothing is live right now.").foregroundStyle(.secondary)
                    Button("Start a 1-Minute Timer") { env.timers.start(minutes: 1, label: "Preview timer") }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if model == nil {
                let m = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                model = m
            }
            sampleAlert = IslandAlert(kind: .battery, style: .chargerConnected(percent: env.battery.info.percent), holdSeconds: 0)
            apply()
        }
        .onChange(of: state) { apply() }
    }

    private func apply() {
        guard let model else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
            switch state {
            case .compact: model.forced = .compact
            case .expanded: model.forced = .expanded(activityID: "")
            case .dashboard: model.forced = .dashboard
            case .alert: model.forced = .alert(sampleAlert)
            }
        }
    }

    private func canvas(_ model: IslandViewModel) -> some View {
        PreviewCanvas(model: model, availableWidth: availableWidth)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geo in
                    Color.clear.onAppear { availableWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in availableWidth = w }
                }
            }
    }
}

/// Draws the island at full size, then scales it from the top-left corner
/// and gives the result exactly the scaled size, so layout and drawing agree
/// (scaleEffect alone leaves the original size in layout and hit testing).
struct PreviewCanvas: View {
    let model: IslandViewModel
    let availableWidth: CGFloat
    static let width: CGFloat = 760

    var body: some View {
        let canvasHeight = model.outerSize.height + 56
        let scale = min(1, max(0.3, availableWidth / Self.width))
        ZStack(alignment: .top) {
            Wallpaper()
                .frame(width: Self.width, height: canvasHeight)
            IslandRootView(model: model)
                .frame(width: Self.width, height: canvasHeight, alignment: .top)
        }
        .frame(width: Self.width, height: canvasHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: Self.width * scale, height: canvasHeight * scale, alignment: .topLeading)
        .clipped()
        // A picture, not a control: clicks go to the picker and the form.
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Island preview")
    }
}

/// The current desktop picture, or a neutral gradient.
private struct Wallpaper: View {
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(hex: "#1B1F4B"), Color(hex: "#5A3AA8"), Color(hex: "#C9566B")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onAppear {
            guard image == nil, let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
            image = NSImage(contentsOf: url)
        }
    }
}
