import IslandCore
import SwiftUI

/// The compact island in either style: ears beside the camera, or a band below it.
struct CompactView: View {
    let model: IslandViewModel

    var body: some View {
        let ranked = model.compactFit.ranked
        if let primary = ranked.primary {
            Group {
                switch model.settings.compactStyle {
                case .beside: beside(primary: primary, ranked: ranked)
                case .below: below(primary: primary, ranked: ranked)
                }
            }
            // Tucked under the camera: nothing in there can be clicked by accident.
            .allowsHitTesting(!model.isTucked)
            // VoiceOver: one element that reads what's live, with actions.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.tap() }
            .accessibilityAction(named: "Open dashboard") { model.openDashboard() }
            .accessibilityAction(named: "Open shelf") { model.openShelf() }
        }
    }

    private func beside(primary: Activity, ranked: RankedActivities) -> some View {
        let notchW = model.notch.rect.width
        // Laid out at the full compact width even while tucked (see `ears`).
        let ear = max(0, (model.layoutSize.width - notchW) / 2)
        let inner = max(0, ear - IslandMetrics.earOuterPadding - IslandMetrics.earInnerGap)
        return VStack(spacing: 0) {
            ears(primary: primary, ranked: ranked, inner: inner, notchW: notchW)
            if let track = model.peekingTrack {
                // The collar grows down behind it, so it reads like the ears.
                PeekTitle(info: track, reduceMotion: model.reduceMotion)
                    .padding(.horizontal, IslandMetrics.shoulder + IslandMetrics.earOuterPadding)
                    .padding(.top, 2)
                    .modifier(EarForeground(material: model.material))
                    .modifier(MediaHotspot(model: model, key: "title"))
                    .transition(.peekRow)
            }
        }
    }

    /// Each ear holds what `CompactEars` gave it: the primary's own content on
    /// its side, then the app icons and other activities balanced across both.
    private func ears(primary: Activity, ranked: RankedActivities, inner: CGFloat, notchW: CGFloat) -> some View {
        let ears = model.compactFit.ears
        let apps: [RunningAppInfo] = if case .backgroundApps(let a) = primary.payload { a } else { [] }
        let leadingApps = Array(apps.prefix(ears.leadingApps))
        let trailingApps = Array(apps.dropFirst(ears.leadingApps).prefix(ears.trailingApps))
        let leadingOthers = ranked.secondaries.filter { ears.leadingSecondaries.contains($0.id) }
        let trailingOthers = ranked.secondaries.filter { ears.trailingSecondaries.contains($0.id) }
        // Tucked: each ear slides in by its own width, riding the island's
        // closing edge until it's under the camera; the shape clips the rest.
        let shift = model.isTucked ? IslandMetrics.earOuterPadding + inner + IslandMetrics.earInnerGap : 0
        return HStack(spacing: 0) {
            HStack(spacing: IslandMetrics.glyphSpacing) {
                if primary.kind != .backgroundApps { CompactLeading(activity: primary, model: model) }
                if !leadingApps.isEmpty { AppIconRow(apps: leadingApps) }
                if !leadingOthers.isEmpty { SecondaryGlyphs(activities: leadingOthers, model: model) }
            }
            .frame(width: inner, alignment: .leading)
            .padding(.leading, IslandMetrics.earOuterPadding)
            .padding(.trailing, IslandMetrics.earInnerGap)
            .modifier(RevealContent(model: model, anchor: .leading))
            .offset(x: shift)
            Color.clear.frame(width: notchW)
            HStack(spacing: IslandMetrics.glyphSpacing) {
                if primary.kind != .backgroundApps { CompactTrailing(activity: primary, model: model) }
                if !trailingApps.isEmpty { AppIconRow(apps: trailingApps) }
                if !trailingOthers.isEmpty { SecondaryGlyphs(activities: trailingOthers, model: model) }
                if model.showsDashboardButton { DashboardButton(model: model) }
            }
            .frame(width: inner, alignment: .trailing)
            .padding(.leading, IslandMetrics.earInnerGap)
            .padding(.trailing, IslandMetrics.earOuterPadding)
            .modifier(RevealContent(model: model, anchor: .trailing))
            .offset(x: -shift)
            // Curtain: the right ear follows the right side's own, later clock.
            .modifier(OptionalAnimation(animation: model.revealStyle == .curtain
                ? IslandMotion.curtainTrailing(opening: !model.isTucked) : nil, value: model.isTucked))
        }
        .frame(height: model.notch.rect.height)
        .padding(.horizontal, IslandMetrics.shoulder)
        .font(.system(size: 13, weight: .semibold))
        .modifier(EarForeground(material: model.material))
    }

    private func below(primary: Activity, ranked: RankedActivities) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.rect.height)
            HStack(spacing: 8) {
                BelowBand(activity: primary, model: model)
                if !ranked.secondaries.isEmpty { SecondaryGlyphs(activities: Array(ranked.secondaries), model: model) }
                if model.showsDashboardButton { DashboardButton(model: model) }
            }
            .padding(.horizontal, 14)
            .frame(height: IslandMetrics.belowBand - 2)
            .modifier(RevealContent(model: model, anchor: .center))
            // Tucked: the band rides up into the notch as the island closes.
            .offset(y: model.isTucked ? -IslandMetrics.belowBand : 0)
            if let track = model.peekingTrack, !track.artist.isEmpty {
                // The band shows the title; the artist goes under it, aligned with it.
                Text(track.artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14 + 18 + 8)
                    .padding(.trailing, 14)
                    .modifier(MediaHotspot(model: model, key: "title"))
                    .transition(.peekRow)
            }
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .font(.system(size: 12, weight: .semibold))
    }
}

// MARK: beside-the-notch ears

private struct CompactLeading: View {
    let activity: Activity
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch activity.payload {
        case .nowPlaying:
            ArtworkView(image: env.nowPlaying.artwork, size: 20, radius: 5)
                .modifier(MediaHotspot(model: model, key: "artwork"))
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 2.5).frame(width: 17, height: 17)
            }
        case .calendar(let e):
            Image(systemName: "calendar").foregroundStyle(Color(hex: e.calendarColorHex))
        case .battery:
            Image(systemName: "battery.25percent").foregroundStyle(.red)
        case .backgroundApps:
            EmptyView() // its icons are placed by the ears
        case .shelf, .download, .privacy:
            Phase2Leading(payload: activity.payload)
        }
    }
}

private struct CompactTrailing: View {
    let activity: Activity
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch activity.payload {
        case .nowPlaying(let info):
            Waveform(playing: info.isPlaying, color: env.nowPlaying.artworkColor.map(Color.init(nsColor:)) ?? .pink)
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(IslandFormat.countdown(t.remaining(at: ctx.date)))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
            }
        case .calendar(let e):
            TimelineView(.everyMinute) { ctx in
                Text(IslandFormat.untilShort(e.start, from: ctx.date)).foregroundStyle(Color(hex: e.calendarColorHex))
            }
        case .battery(let b):
            Text("\(b.percent)%").monospacedDigit().foregroundStyle(.red)
        case .backgroundApps:
            EmptyView() // its icons are placed by the ears
        case .shelf, .download, .privacy:
            Phase2Trailing(payload: activity.payload)
        }
    }
}

// MARK: below-the-notch band

private struct BelowBand: View {
    let activity: Activity
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch activity.payload {
        case .nowPlaying(let info):
            ArtworkView(image: env.nowPlaying.artwork, size: 18, radius: 5)
                .modifier(MediaHotspot(model: model, key: "artwork"))
            if model.peekingTrack != nil {
                MarqueeText(text: info.title, font: .system(size: 12, weight: .semibold), reduceMotion: model.reduceMotion)
            } else {
                Text(info.title).lineLimit(1)
            }
            Spacer(minLength: 4)
            Waveform(playing: info.isPlaying, color: env.nowPlaying.artworkColor.map(Color.init(nsColor:)) ?? .pink)
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 8) {
                    Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 2.5).frame(width: 15, height: 15)
                    Text(t.label).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(IslandFormat.countdown(t.remaining(at: ctx.date))).monospacedDigit().foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
        case .calendar(let e):
            Image(systemName: "calendar").foregroundStyle(Color(hex: e.calendarColorHex))
            Text(e.title).lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.everyMinute) { ctx in
                Text(IslandFormat.untilShort(e.start, from: ctx.date)).foregroundStyle(Color(hex: e.calendarColorHex))
            }
        case .battery(let b):
            Image(systemName: "battery.25percent").foregroundStyle(.red)
            Text("Low battery").lineLimit(1)
            Spacer(minLength: 4)
            Text("\(b.percent)%").monospacedDigit().foregroundStyle(.red)
        case .backgroundApps(let apps):
            Spacer(minLength: 0)
            AppIconRow(apps: Array(apps.prefix(model.compactFit.iconLimit)))
            Spacer(minLength: 0)
        case .shelf, .download, .privacy:
            Phase2Band(payload: activity.payload)
        }
    }
}

// MARK: shared pieces

/// App icons in a row. Each switches to its app, unless the row is part of a
/// bigger button (`activates: false`).
struct AppIconRow: View {
    let apps: [RunningAppInfo]
    var size: CGFloat = IslandMetrics.glyph
    var activates = true
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: IslandMetrics.glyphSpacing) {
            ForEach(apps) { app in
                if activates {
                    Button { env.backgroundApps.activate(app) } label: { AppIcon(app: app, size: size) }
                        .buttonStyle(.plain)
                        .help(app.name)
                } else {
                    AppIcon(app: app, size: size)
                }
            }
        }
    }
}

/// "+N" for what didn't fit, in the dashboard (the compact island never shows one).
struct OverflowChip: View {
    let count: Int
    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minWidth: IslandMetrics.overflowChipWidth(count), minHeight: 18)
            // Follows the ear's foreground, so it reads on black and on glass.
            .background(Capsule().fill(.quaternary))
            .accessibilityLabel("\(count) more")
    }
}

/// Minimal glyphs for the activities after the primary one; click to open one.
private struct SecondaryGlyphs: View {
    let activities: [Activity]
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: IslandMetrics.glyphSpacing) {
            ForEach(activities) { a in
                Button { model.open(a.id) } label: { glyph(a) }
                    .buttonStyle(.plain)
                    .help(tooltip(a))
            }
        }
    }

    private func tooltip(_ a: Activity) -> String {
        if case .nowPlaying(let i) = a.payload, !i.title.isEmpty {
            return i.artist.isEmpty ? i.title : "\(i.title) — \(i.artist)"
        }
        if case .backgroundApps(let apps) = a.payload { return "Open apps · \(apps.count)" }
        return a.kind.displayName
    }

    @ViewBuilder private func glyph(_ a: Activity) -> some View {
        switch a.payload {
        case .nowPlaying:
            ArtworkView(image: env.nowPlaying.artwork, size: 18, radius: 9)
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 2.2).frame(width: 16, height: 16)
            }
            .frame(width: 20, height: 20)
        case .calendar(let e):
            Image(systemName: "calendar").foregroundStyle(Color(hex: e.calendarColorHex)).frame(width: 20, height: 20)
        case .battery:
            Image(systemName: "battery.25percent").foregroundStyle(.red).frame(width: 20, height: 20)
        case .backgroundApps(let apps):
            // The first app's own icon: a grid glyph would look like the dashboard button.
            if let first = apps.first {
                AppIcon(app: first, size: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
        case .shelf, .download, .privacy:
            Phase2Glyph(payload: a.payload)
        }
    }
}

// MARK: title on hover

/// The track's title and artist under the ears, shown after the pointer rests
/// on the compact island. Long titles scroll.
private struct PeekTitle: View {
    let info: NowPlayingInfo
    let reduceMotion: Bool
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let tint = env.nowPlaying.artworkColor.map(Color.init(nsColor:)) ?? .pink
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: info.title, font: .system(size: 12.5, weight: .semibold), reduceMotion: reduceMotion)
                if !info.artist.isEmpty {
                    MarqueeText(text: info.artist, font: .system(size: 11, weight: .medium), reduceMotion: reduceMotion)
                        .opacity(0.68)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension AnyTransition {
    /// The row rides the same spring as the shape, sliding down with the
    /// growing edge (the shape's clip reveals it), and fades out quickly.
    static var peekRow: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity.animation(IslandMotion.peekRowOut)
        )
    }
}

/// The content's part in a reveal: Ink spread fades and sharpens it in after
/// the edges, Elastic pop springs it up from small; Slide and Curtain leave it
/// riding the edges as it is.
private struct RevealContent: ViewModifier {
    let model: IslandViewModel
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        let tucked = model.isTucked
        let style = model.revealStyle
        content
            .opacity(tucked && (style == .ink || style == .elastic) ? 0 : 1)
            .blur(radius: tucked && style == .ink ? 4 : 0)
            .scaleEffect(tucked ? (style == .ink ? 0.92 : style == .elastic ? 0.55 : 1) : 1, anchor: anchor)
            .modifier(OptionalAnimation(animation: style.flatMap { IslandMotion.revealContent($0, opening: !tucked) }, value: tucked))
    }
}

/// Reports where the track's artwork (or its open title row) is, so the
/// controller can show the title only while the pointer is on it.
struct MediaHotspot: ViewModifier {
    let model: IslandViewModel
    let key: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandRootView.space)) } action: { model.mediaRects[key] = $0 }
            .onDisappear { model.mediaRects[key] = nil }
    }
}
