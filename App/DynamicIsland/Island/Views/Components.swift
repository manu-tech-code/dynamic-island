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
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.9)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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

/// Animated waveform like the iPhone's Now Playing ear. Static when paused or with Reduce Motion.
struct Waveform: View {
    let playing: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: playing && !reduceMotion)
            .foregroundStyle(color)
            .opacity(playing ? 1 : 0.45)
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
struct IslandCapsuleButton: View {
    let title: String
    var systemName: String?
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemName { Image(systemName: systemName) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
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

/// Card inside the dashboard: fill instead of glass, radius concentric with the island.
struct IslandCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.primary.opacity(0.07)))
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
        }
    }
}
