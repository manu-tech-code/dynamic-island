import AppKit
import IslandCore
import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x0A84FF
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Foreground for content that sits on the black collar beside the notch.
struct EarForeground: ViewModifier {
    let material: IslandMaterial
    func body(content: Content) -> some View {
        if material == .glass { content.foregroundStyle(.primary) } else { content.foregroundStyle(.white) }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.9)))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // A new track cross-fades its artwork instead of swapping it.
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }
}

struct AppIcon: View {
    let app: RunningAppInfo
    let size: CGFloat
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Image(nsImage: env.backgroundApps.icon(for: app))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel(app.name)
    }
}

struct Ring: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct ProgressTrack: View {
    let fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule().fill(.primary).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// One line of text that scrolls slowly when it doesn't fit, pausing at the
/// start of each pass. With Reduce Motion it truncates instead. Only runs a
/// timeline while it overflows and is on screen.
struct MarqueeText: View {
    let text: String
    let font: Font
    let reduceMotion: Bool
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date()
    private let gap: CGFloat = 32
    private let speed: CGFloat = 30   // points per second
    private let pause: Double = 1.6

    var body: some View {
        let scrolls = !reduceMotion && boxWidth > 0 && textWidth > boxWidth + 0.5
        Text(text)
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(scrolls ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    // 30 fps: a point a frame at this speed, and half the redraws of 60.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let travel = textWidth + gap
                        let cycle = pause + Double(travel / speed)
                        let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                        let x = t < pause ? 0 : -CGFloat(t - pause) * speed
                        HStack(spacing: gap) { Text(text); Text(text) }
                            .font(font)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: x)
                            // Both bounds, so the frame takes the box's width instead of the text's.
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            // The leading edge only fades while the text is moving.
                            .mask(LinearGradient(stops: [.init(color: x < 0 ? .clear : .black, location: 0),
                                                         .init(color: .black, location: 0.05),
                                                         .init(color: .black, location: 0.88),
                                                         .init(color: .clear, location: 1)],
                                                 startPoint: .leading, endPoint: .trailing))
                    }
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: text) { start = .now }
    }
}

/// Round icon button with a hover fill, 28 pt by default (HIG minimum on macOS).
struct IslandIconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var weight: Font.Weight = .semibold
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: weight))
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Capsule button for island content ("Join", presets). Not glass: no glass on glass.
/// `fillWidth` stretches it to its grid cell so rows of buttons line up.
struct IslandCapsuleButton: View {
    let title: String
    var systemName: String?
    var prominent = false
    var fillWidth = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemName { Image(systemName: systemName) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, fillWidth ? 6 : 12)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(height: 26)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.85 : 1))
                                                 : AnyShapeStyle(.primary.opacity(hovering ? 0.18 : 0.1))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One click to the dashboard, from the compact island or any open state.
struct DashboardButton: View {
    let model: IslandViewModel
    var size: CGFloat = 22

    var body: some View {
        IslandIconButton(systemName: "square.grid.2x2.fill", size: size, label: "Open dashboard") {
            model.openDashboard()
        }
    }
}

/// Card inside the dashboard: fill instead of glass (no glass on glass), and a
/// radius concentric with the island (outer radius minus the padding).
struct IslandCard<Content: View>: View {
    var title: String
    var symbol: String?
    var radius: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title.uppercased()).tracking(0.6).lineLimit(1)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

extension ActivityKind {
    var tint: Color {
        switch self {
        case .nowPlaying: .pink
        case .timer: .orange
        case .calendar: .red
        case .battery: .green
        case .backgroundApps: .blue
        case .shelf: .teal
        case .downloads: .blue
        case .privacy: .orange
        case .devices: .indigo
        case .hud: .gray
        case .messages: .green
        case .agents: .orange
        }
    }
}

/// The battery as the menu bar draws it: an outline filled as far as the
/// charge goes, green with a bolt while charging, red when it's low.
struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        let level = Double(min(max(percent, 0), 100)) / 100
        let fill: Color = charging ? .green : percent <= 10 ? .red : percent <= 20 ? .orange : .primary
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.primary.opacity(0.45), lineWidth: 1)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                        .fill(fill)
                        .frame(width: max(1.5, g.size.width * level))
                }
                .padding(2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 25, height: 12)
            // The terminal nub.
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1, topTrailingRadius: 1)
                .fill(.primary.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .accessibilityElement()
        .accessibilityLabel(charging ? "Battery \(percent) percent, charging" : "Battery \(percent) percent")
    }
}
