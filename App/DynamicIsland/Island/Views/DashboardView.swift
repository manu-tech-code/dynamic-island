import IslandCore
import SwiftUI

/// The dashboard: background apps beside the camera, then a 4-column grid of
/// widgets the user picks in Settings › Dashboard. Small widgets take one
/// slot, medium ones two, so Now Playing is at most half the width.
struct DashboardView: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    static let slot = (DashboardLayout.width - 28 - CGFloat(DashboardLayout.columns - 1) * DashboardLayout.spacing) / CGFloat(DashboardLayout.columns)

    static func width(_ size: WidgetSize) -> CGFloat {
        CGFloat(size.columns) * slot + CGFloat(size.columns - 1) * DashboardLayout.spacing
    }

    var body: some View {
        let s = model.settings
        let items = s.visibleDashboard
        let rows = DashboardLayout.rows(items)
        let cardRadius = max(12, model.radius - 14)
        VStack(spacing: 0) {
            EarRow(model: model) {
                if s[module: .backgroundApps].enabled {
                    let excluded = Set(s.backgroundApps.excludedBundleIDs)
                    let apps = env.backgroundApps.apps.filter { !excluded.contains($0.bundleID ?? "") }
                    AppIconRow(apps: Array(apps.prefix(7)), size: 20)
                    if apps.count > 7 { OverflowChip(count: apps.count - 7) }
                }
            } trailing: {
                if env.battery.info.hasBattery {
                    Text("\(env.battery.info.percent)%").monospacedDigit()
                    Image(systemName: env.battery.info.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                }
                if s[module: .shelf].enabled {
                    IslandIconButton(systemName: env.shelf.items.isEmpty ? "tray" : "tray.full.fill", size: 24,
                                     label: env.shelf.items.isEmpty ? "Shelf" : "Shelf, \(env.shelf.items.count) items") { model.openShelf() }
                }
                IslandIconButton(systemName: "gearshape.fill", size: 24, label: "Settings") { env.openSettings() }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text("Your dashboard is empty").font(.system(size: 14, weight: .semibold))
                    IslandCapsuleButton(title: "Add Widgets…", prominent: true) { env.openSettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: DashboardLayout.spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: DashboardLayout.spacing) {
                            ForEach(row) { item in
                                WidgetView(item: item, radius: cardRadius, model: model)
                                    .frame(width: Self.width(item.size), height: DashboardLayout.cardHeight)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, DashboardLayout.topPadding)
                .padding(.bottom, DashboardLayout.bottomPadding)
            }
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if items.contains(where: \.kind.isSystemStat) { env.systemStats.acquire() } }
        .onDisappear { if items.contains(where: \.kind.isSystemStat) { env.systemStats.release() } }
    }
}

struct WidgetView: View {
    let item: DashboardItem
    let radius: CGFloat
    let model: IslandViewModel

    var body: some View {
        IslandCard(title: item.kind.displayName, symbol: item.kind.symbolName, radius: radius) {
            switch item.kind {
            case .nowPlaying: NowPlayingWidget(size: item.size)
            case .calendar: CalendarWidget(size: item.size)
            case .timer: TimerWidget()
            case .battery: BatteryWidget()
            case .cpu: CPUWidget(size: item.size)
            case .memory: MemoryWidget()
            case .storage: StorageWidget()
            case .network: NetworkWidget(size: item.size)
            case .weather: WeatherWidget(size: item.size)
            case .shelf: ShelfWidget(size: item.size, model: model)
            case .clipboard: ClipboardWidget(size: item.size)
            case .shortcuts: ShortcutsWidget(size: item.size)
            case .devices: DevicesWidget(size: item.size)
            }
        }
    }
}

// MARK: widgets

private struct NowPlayingWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        if let info = np.info {
            if size == .medium {
                HStack(spacing: 10) {
                    ArtworkView(image: np.artwork, size: 48, radius: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(info.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ArtworkView(image: np.artwork, size: 36, radius: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(info.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(info.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: info.isPlaying ? 1 : 3600)) { ctx in
                ProgressTrack(fraction: info.progress(at: ctx.date) ?? 0, height: 4)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            HStack {
                IslandIconButton(systemName: "backward.fill", size: 28, label: "Previous track") { np.previous() }
                Spacer()
                IslandIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 34, label: info.isPlaying ? "Pause" : "Play") { np.togglePlayPause() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                IslandIconButton(systemName: "forward.fill", size: 28, label: "Next track") { np.next() }
            }
        } else {
            Spacer(minLength: 0)
            Text("Nothing playing").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }
}

private struct CalendarWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cal = env.calendar
        switch cal.access {
        case .granted:
            TimelineView(.everyMinute) { ctx in
                let events = Array(cal.upcoming.filter { $0.end > ctx.date }.prefix(size == .medium ? 3 : 2))
                if events.isEmpty {
                    Text("Nothing else today or tomorrow").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(events) { e in EventRow(event: e, now: ctx.date) }
                    }
                    Spacer(minLength: 0)
                    if let first = events.first, let url = first.joinURL, first.start.timeIntervalSince(ctx.date) < 30 * 60 {
                        IslandCapsuleButton(title: "Join", systemName: "video.fill", prominent: true) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        case .notDetermined:
            Text("See your next event here.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            IslandCapsuleButton(title: "Allow Access", prominent: true) { cal.requestAccess() }
        case .denied:
            Text("Calendar access is off.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            IslandCapsuleButton(title: "Open Settings") { cal.openPrivacySettings() }
        }
    }
}

private struct EventRow: View {
    let event: CalendarEventInfo
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Color(hex: event.calendarColorHex)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var detail: String {
        let time = event.start.formatted(date: Calendar.current.isDateInToday(event.start) ? .omitted : .abbreviated, time: .shortened)
        return event.isInProgress(at: now) ? "\(time) · now" : "\(time) · \(IslandFormat.untilLong(event.start, from: now))"
    }
}

private struct TimerWidget: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let timers = env.timers
        if let t = timers.running {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 10) {
                    Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 4)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(IslandFormat.countdown(t.remaining(at: ctx.date)))
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                        Text(t.label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                IslandIconButton(systemName: t.isRunning ? "pause.fill" : "play.fill", size: 28, label: t.isRunning ? "Pause" : "Resume") {
                    t.isRunning ? timers.pause(t.id) : timers.resume(t.id)
                }
                IslandIconButton(systemName: "plus", size: 28, label: "Add a minute") { timers.addMinute(t.id) }
                Spacer()
                IslandIconButton(systemName: "xmark", size: 28, label: "Cancel timer") { timers.cancel(t.id) }
            }
        } else {
            let presets = Array(env.settings.settings.timers.presetMinutes.prefix(6))
            Spacer(minLength: 0)
            // Full-width cells in a leading-aligned grid, so an odd last preset
            // lines up under the left column instead of floating.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    IslandCapsuleButton(title: m >= 60 && m % 60 == 0 ? "\(m / 60) h" : "\(m) min", fillWidth: true) {
                        timers.start(minutes: Double(m))
                    }
                }
            }
        }
    }
}

private struct BatteryWidget: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let b = env.battery.info
        HStack(spacing: 10) {
            BatteryRing(info: b, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(b.percent)%").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(BatteryText.state(b)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        Spacer(minLength: 0)
        Text(BatteryText.detail(b)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
    }
}

private struct CPUWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let stats = env.systemStats
        StatValue(value: "\(Int((stats.cpu * 100).rounded()))%", detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
        Spacer(minLength: 4)
        Sparkline(values: stats.cpuHistory, maxValue: 1, color: stats.cpu > 0.8 ? .red : .blue)
            .frame(height: size == .medium ? 56 : 40)
    }
}

private struct MemoryWidget: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let stats = env.systemStats
        let color: Color = switch stats.memoryPressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
        StatValue(value: ByteFormat.memory(stats.memoryUsed), detail: "of \(ByteFormat.memory(stats.memoryTotal))")
        Spacer(minLength: 4)
        MeterBar(fraction: stats.memoryFraction, color: color)
        Text(stats.memoryPressure == .normal ? "Pressure normal" : stats.memoryPressure == .warning ? "Pressure high" : "Pressure critical")
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
    }
}

private struct StorageWidget: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let stats = env.systemStats
        StatValue(value: ByteFormat.size(stats.diskFree), detail: "free of \(ByteFormat.size(stats.diskTotal))")
        Spacer(minLength: 4)
        MeterBar(fraction: stats.diskUsedFraction, color: stats.diskUsedFraction > 0.9 ? .red : .purple)
        Text("Macintosh HD").font(.system(size: 10.5)).foregroundStyle(.secondary)
    }
}

private struct NetworkWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let stats = env.systemStats
        HStack(spacing: 12) {
            Label(ByteFormat.rate(stats.netIn), systemImage: "arrow.down").foregroundStyle(.cyan)
            Label(ByteFormat.rate(stats.netOut), systemImage: "arrow.up").foregroundStyle(.orange)
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .labelStyle(.titleAndIcon)
        Spacer(minLength: 4)
        let peak = max(1024, (stats.netInHistory + stats.netOutHistory).max() ?? 0)
        ZStack {
            Sparkline(values: stats.netInHistory, maxValue: peak, color: .cyan)
            Sparkline(values: stats.netOutHistory, maxValue: peak, color: .orange, fill: false)
        }
        .frame(height: size == .medium ? 56 : 40)
    }
}

// MARK: pieces

private struct StatValue: View {
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct MeterBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14))
                Capsule().fill(color.gradient).frame(width: g.size.width * max(0.02, min(1, fraction)))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

/// A small line graph with an area fill, newest value on the right.
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double = 1
    let color: Color
    var fill = true

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                if fill, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(color).frame(width: 4, height: 4).position(last)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = SystemStatsService.historyLength
        guard !values.isEmpty, maxValue > 0 else { return [] }
        let step = size.width / CGFloat(max(1, n - 1))
        let offset = CGFloat(n - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: size.height - size.height * CGFloat(min(1, v / maxValue)))
        }
    }
}
