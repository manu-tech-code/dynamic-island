import IslandCore
import SwiftUI

/// The compact island in either style: ears beside the camera, or a band below it.
struct CompactView: View {
    let model: IslandViewModel

    var body: some View {
        let ranked = model.ranked
        if let primary = ranked.primary {
            switch model.settings.compactStyle {
            case .beside: beside(primary: primary, ranked: ranked)
            case .below: below(primary: primary, ranked: ranked)
            }
        }
    }

    private func beside(primary: Activity, ranked: RankedActivities) -> some View {
        let notchW = model.notch.rect.width
        let ear = max(0, (model.bodySize.width - notchW) / 2)
        let inner = max(0, ear - IslandMetrics.earOuterPadding - IslandMetrics.earInnerGap)
        return HStack(spacing: 0) {
            CompactLeading(activity: primary, model: model)
                .frame(width: inner, alignment: .leading)
                .padding(.leading, IslandMetrics.earOuterPadding)
                .padding(.trailing, IslandMetrics.earInnerGap)
            Color.clear.frame(width: notchW)
            HStack(spacing: IslandMetrics.glyphSpacing) {
                CompactTrailing(activity: primary, model: model)
                SecondaryGlyphs(ranked: ranked, model: model)
            }
            .frame(width: inner, alignment: .trailing)
            .padding(.leading, IslandMetrics.earInnerGap)
            .padding(.trailing, IslandMetrics.earOuterPadding)
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
                SecondaryGlyphs(ranked: ranked, model: model)
            }
            .padding(.horizontal, 14)
            .frame(height: IslandMetrics.belowBand - 2)
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
        case .timer(let t):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 2.5).frame(width: 17, height: 17)
            }
        case .calendar(let e):
            Image(systemName: "calendar").foregroundStyle(Color(hex: e.calendarColorHex))
        case .battery:
            Image(systemName: "battery.25percent").foregroundStyle(.red)
        case .backgroundApps(let apps):
            AppIconRow(apps: AppSplit(apps: apps, limit: model.settings.backgroundApps.maxIcons).leading)
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
        case .backgroundApps(let apps):
            let split = AppSplit(apps: apps, limit: model.settings.backgroundApps.maxIcons)
            HStack(spacing: IslandMetrics.glyphSpacing) {
                AppIconRow(apps: split.trailing)
                if split.hidden > 0 { OverflowChip(count: split.hidden) }
            }
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
            Text(info.title).lineLimit(1)
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
            let split = AppSplit(apps: apps, limit: model.settings.backgroundApps.maxIcons)
            Spacer(minLength: 0)
            AppIconRow(apps: split.leading + split.trailing)
            if split.hidden > 0 { OverflowChip(count: split.hidden) }
            Spacer(minLength: 0)
        case .shelf, .download, .privacy:
            Phase2Band(payload: activity.payload)
        }
    }
}

// MARK: shared pieces

/// Background apps split into the two ears; the rest are counted in a chip.
struct AppSplit {
    let leading: [RunningAppInfo]
    let trailing: [RunningAppInfo]
    let hidden: Int

    init(apps: [RunningAppInfo], limit: Int) {
        let shown = Array(apps.prefix(max(1, limit)))
        let left = Int((Double(shown.count) / 2).rounded(.up))
        leading = Array(shown.prefix(left))
        trailing = Array(shown.dropFirst(left))
        hidden = apps.count - shown.count
    }
}

struct AppIconRow: View {
    let apps: [RunningAppInfo]
    var size: CGFloat = IslandMetrics.glyph
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: IslandMetrics.glyphSpacing) {
            ForEach(apps) { app in
                Button { env.backgroundApps.activate(app) } label: { AppIcon(app: app, size: size) }
                    .buttonStyle(.plain)
                    .help(app.name)
            }
        }
    }
}

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
    let ranked: RankedActivities
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if !ranked.secondaries.isEmpty || !ranked.overflow.isEmpty {
            HStack(spacing: IslandMetrics.glyphSpacing) {
                ForEach(Array(ranked.secondaries)) { a in
                    Button { model.open(a.id) } label: { glyph(a) }
                        .buttonStyle(.plain)
                        .help(a.kind.displayName)
                }
                if !ranked.overflow.isEmpty { OverflowChip(count: ranked.overflow.count) }
            }
            .padding(.leading, 2)
        }
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
        case .backgroundApps:
            Image(systemName: "square.grid.2x2.fill").frame(width: 20, height: 20)
        case .shelf, .download, .privacy:
            Phase2Glyph(payload: a.payload)
        }
    }
}
