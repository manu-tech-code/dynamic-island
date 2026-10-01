import IslandCore
import SwiftUI

/// Settings › While music plays: what stays out of a tucked island while a
/// song plays, drawn behind the island. Bubbles and the drop are pulled out
/// of the notch like water and melt back into it when the island comes out
/// over them; the slim ears, the record and the glow slide or fade.
struct PlayingIndicatorView: View {
    let model: IslandViewModel

    var body: some View {
        if let style = model.playingIndicatorStyle {
            let phase = model.indicatorPhase
            Group {
                switch style {
                case .tucked: EmptyView()
                case .slim: SlimEars(model: model, phase: phase)
                case .bubble, .twoBubbles, .drip: Droplets(model: model, style: style, phase: phase)
                case .record: Record(model: model, phase: phase)
                case .underglow: Underglow(model: model, phase: phase)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private extension IslandViewModel {
    /// The waveform's colour, from the artwork.
    var tint: Color { env.nowPlaying.artworkColor.map(Color.init(nsColor:)) ?? .pink }

    /// The artwork's colour made bright enough to glow, even from a dark cover.
    var glowTint: Color {
        guard let c = env.nowPlaying.artworkColor?.usingColorSpace(.deviceRGB) else { return .pink }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: max(s, 0.55), brightness: max(b, 0.95))
    }
}

// MARK: artwork and waveform

/// Slim ears beside the notch with only the artwork and the waveform. They
/// grow with the island as it comes out over them, and close back in with it.
private struct SlimEars: View {
    let model: IslandViewModel
    let phase: IslandViewModel.IndicatorPhase

    var body: some View {
        let n = model.notch.rect.size
        let s = IslandMetrics.shoulder
        let idle = IslandMetrics.idleSize(notch: n).width
        let width: CGFloat = switch phase {
        case .shown: n.width + 2 * IslandMetrics.playingSlimEar
        case .absorbed: model.presentation == .compact ? model.layoutSize.width : idle
        case .hidden: idle
        }
        let shown = phase == .shown
        let fade = shown ? IslandMotion.indicatorContentIn : IslandMotion.indicatorContentOut
        let shape = NotchShape(bottomRadius: IslandMetrics.radius(forHeight: n.height), shoulder: s)
        ZStack {
            if model.material == .glass {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.black)
            }
            ArtworkView(image: model.env.nowPlaying.artwork, size: 20, radius: 5)
                .animation(fade) { $0.opacity(shown ? 1 : 0) }
                .offset(x: -width / 2 + 8 + 10)
            Waveform(playing: true, color: model.tint)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
                .animation(fade) { $0.opacity(shown ? 1 : 0) }
                .offset(x: width / 2 - 8 - 10)
        }
        .frame(width: width + 2 * s, height: n.height)
        // The island's own reveal spring, so the ears and the island move as one.
        .animation(model.reduceMotion ? IslandMotion.reduced
                   : IslandMotion.revealShape(model.settings.revealStyle, opening: phase == .absorbed), value: phase)
    }
}

// MARK: bubbles and the drop

/// A bubble beside the notch or the drop below it, at a progress from 0
/// (inside the notch, small) to 1 (out). Linear in the progress, so the
/// shapes and what's in them move together under one animation.
nonisolated private enum Droplet: Hashable {
    case left, right, drop

    static func all(_ style: PlayingStyle) -> [Droplet] {
        switch style {
        case .bubble: [.right]
        case .twoBubbles: [.left, .right]
        case .drip: [.drop]
        default: []
        }
    }

    /// Centre (from the top centre of the notch) and diameter.
    func circle(notch n: CGSize, progress p: CGFloat) -> (center: CGPoint, diameter: CGFloat) {
        switch self {
        case .left, .right:
            let d = IslandMetrics.playingBubbleDiameter(notch: n)
            let inside = n.width / 2 - d / 2 - 2
            let outside = n.width / 2 + IslandMetrics.playingBubbleGap + d / 2
            let x = inside + (outside - inside) * p
            return (CGPoint(x: self == .right ? x : -x, y: 1 + d / 2), d * (0.5 + 0.5 * p))
        case .drop:
            let d = IslandMetrics.playingDropDiameter
            let inside = n.height / 2, outside = n.height + IslandMetrics.playingDropGap + d / 2
            return (CGPoint(x: 0, y: inside + (outside - inside) * p), d * (0.4 + 0.6 * p))
        }
    }

    /// Room for the bubbles on both sides and the drop below.
    static func canvasSize(notch n: CGSize) -> CGSize {
        CGSize(width: n.width + 2 * (IslandMetrics.playingBubbleGap + IslandMetrics.playingBubbleDiameter(notch: n) + 16),
               height: n.height + IslandMetrics.playingDropGap + IslandMetrics.playingDropDiameter + 12)
    }
}

private struct Droplets: View {
    let model: IslandViewModel
    let style: PlayingStyle
    let phase: IslandViewModel.IndicatorPhase

    var body: some View {
        let n = model.notch.rect.size
        let size = Droplet.canvasSize(notch: n)
        let drops = Droplet.all(style)
        let shown = phase == .shown
        let progress: CGFloat = shown ? 1 : 0
        let motion = model.reduceMotion ? IslandMotion.reduced : shown ? IslandMotion.dropletOut(style) : IslandMotion.dropletIn
        let fade = model.reduceMotion ? IslandMotion.reduced : shown ? IslandMotion.indicatorContentIn : IslandMotion.indicatorContentOut
        ZStack(alignment: .topLeading) {
            GooShapes(drops: drops, notch: n, progress: progress)
            ForEach(drops, id: \.self) { drop in
                let rest = drop.circle(notch: n, progress: 1)
                let now = drop.circle(notch: n, progress: progress)
                inside(drop, diameter: rest.diameter)
                    .animation(fade) { $0.opacity(shown ? 1 : 0) }
                    .scaleEffect(now.diameter / rest.diameter)
                    .position(x: size.width / 2 + now.center.x, y: now.center.y)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(motion, value: phase)
    }

    @ViewBuilder private func inside(_ drop: Droplet, diameter d: CGFloat) -> some View {
        if style == .twoBubbles, drop == .right {
            Waveform(playing: true, color: model.tint)
                .font(.system(size: d * 0.42, weight: .semibold))
        } else {
            let art = d - 2 * (drop == .drop ? 3 : 4)
            ArtworkView(image: model.env.nowPlaying.artwork, size: art, radius: art / 2)
        }
    }
}

/// The black shapes, melted together: the notch, the bubbles and the drop
/// with its neck. Blurred, then cut at half coverage, so shapes near each
/// other join like water and pull apart with a neck that snaps.
nonisolated private struct GooShapes: View, Animatable {
    var drops: [Droplet]
    var notch: CGSize
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            // A hair of blur on the cut edge, so it isn't jagged.
            ctx.addFilter(.blur(radius: 0.5))
            ctx.drawLayer { goo in
                goo.addFilter(.alphaThreshold(min: 0.5, color: .black))
                goo.addFilter(.blur(radius: 3.5))
                goo.drawLayer { s in
                    // The notch (under the camera, so only the joins show), running off the top.
                    let r: CGFloat = 10
                    s.fill(Path(roundedRect: CGRect(x: cx - notch.width / 2, y: -r, width: notch.width, height: notch.height + r),
                                cornerRadius: r, style: .continuous), with: .color(.black))
                    for drop in drops {
                        let c = drop.circle(notch: notch, progress: progress)
                        s.fill(Path(ellipseIn: CGRect(x: cx + c.center.x - c.diameter / 2, y: c.center.y - c.diameter / 2,
                                                      width: c.diameter, height: c.diameter)), with: .color(.black))
                        if drop == .drop, progress > 0.02 {
                            // The neck the drop hangs from.
                            let w: CGFloat = 9, top = notch.height - 8
                            s.fill(Path(roundedRect: CGRect(x: cx - w / 2, y: top, width: w, height: max(0, c.center.y - top)),
                                        cornerRadius: w / 2), with: .color(.black))
                        }
                    }
                }
            }
        }
    }
}

// MARK: record

/// A record with the artwork as its label, peeking out from behind the notch
/// and spinning while the song plays. It rolls away under the notch when the
/// island comes out, and when the music stops.
private struct Record: View {
    let model: IslandViewModel
    let phase: IslandViewModel.IndicatorPhase

    var body: some View {
        let n = model.notch.rect.size
        let d = IslandMetrics.playingBubbleDiameter(notch: n)
        let shown = phase == .shown
        // Out: its right edge `playingRecordPeek` past the notch. In: fully behind it.
        let x = shown ? n.width / 2 + IslandMetrics.playingRecordPeek - d / 2 : n.width / 2 - d / 2 - 8
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shown || model.reduceMotion)) { ctx in
            let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            disc(d).rotationEffect(.degrees(turn * 360))
        }
        // The light on it stays put while it turns.
        .overlay {
            AngularGradient(stops: [.init(color: .clear, location: 0.08), .init(color: .white.opacity(0.14), location: 0.12),
                                    .init(color: .clear, location: 0.17), .init(color: .clear, location: 0.58),
                                    .init(color: .white.opacity(0.1), location: 0.62), .init(color: .clear, location: 0.67)],
                            center: .center, angle: .degrees(20))
                .clipShape(Circle())
        }
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        .offset(x: x, y: 1)
        .frame(width: n.width + 2 * (d + 24), height: n.height, alignment: .top)
        .animation(model.reduceMotion ? IslandMotion.reduced : shown ? IslandMotion.recordOut : IslandMotion.dropletIn, value: phase)
    }

    private func disc(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.08))
            ForEach(1..<5, id: \.self) { i in
                Circle().strokeBorder(.white.opacity(0.07), lineWidth: 0.5).padding(CGFloat(i) * 2.2)
            }
            ArtworkView(image: model.env.nowPlaying.artwork, size: d * 0.38, radius: d * 0.19)
            Circle().fill(Color(white: 0.05)).frame(width: 3, height: 3)
        }
        .frame(width: d, height: d)
    }
}

// MARK: underglow

/// No shapes at all: a soft glow in the artwork's colour under the notch, pulsing.
private struct Underglow: View {
    let model: IslandViewModel
    let phase: IslandViewModel.IndicatorPhase

    var body: some View {
        let n = model.notch.rect.size
        let shown = phase == .shown
        let tint = model.glowTint
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shown || model.reduceMotion)) { ctx in
            let beat = model.reduceMotion ? 1 : (sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8) + 1) / 2
            Capsule()
                .fill(LinearGradient(colors: [tint.opacity(0.75), tint, tint.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                .frame(width: n.width - 16, height: 10)
                .scaleEffect(x: 0.84 + 0.16 * beat)
                .opacity(0.55 + 0.45 * beat)
                .blur(radius: 4)
        }
        // Centred on the notch's bottom edge: only the half below it shows.
        .padding(.top, n.height - 5)
        .animation(model.reduceMotion ? IslandMotion.reduced : shown ? IslandMotion.glowIn : IslandMotion.glowOut) {
            $0.opacity(shown ? 1 : 0)
        }
    }
}

#if DEBUG
/// Offline frames of the bubbles and the drop coming out of the notch, at a
/// few points of the motion, for checking the joins. Black notch on top, as
/// the camera housing would be.
struct PlayingIndicatorFrames: View {
    var notch = CGSize(width: 185, height: 32)
    let steps: [CGFloat] = [0, 0.2, 0.35, 0.5, 0.65, 0.8, 1, 1.1]

    var body: some View {
        let size = Droplet.canvasSize(notch: notch)
        VStack(alignment: .leading, spacing: 6) {
            ForEach([PlayingStyle.bubble, .twoBubbles, .drip], id: \.self) { style in
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { p in
                        ZStack(alignment: .top) {
                            LinearGradient(colors: [Color(hex: "#5A3AA8"), Color(hex: "#C9566B")], startPoint: .leading, endPoint: .trailing)
                            GooShapes(drops: Droplet.all(style), notch: notch, progress: p)
                                .frame(width: size.width, height: size.height)
                            NotchShape(bottomRadius: 10, shoulder: 0).fill(Color(white: 0.16))
                                .frame(width: notch.width, height: notch.height)
                            Text(String(format: "%.2f", p)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.top, size.height - 16)
                        }
                        .frame(width: size.width, height: size.height)
                    }
                }
            }
        }
        .padding(8)
        .background(.black)
    }
}
#endif
