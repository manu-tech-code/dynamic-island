import IslandCore
import SwiftUI

/// The dashboard: background apps beside the camera, then a 4-column grid of
/// widgets the user picks in Settings › Dashboard. Small widgets take one
/// slot, medium ones two, so Now Playing is at most half the width.
struct DashboardView: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    /// App icons that fit in an ear, leaving room for a "+N" chip when some don't.
    static func iconsThatFit(_ count: Int, in width: CGFloat) -> Int {
        let step = IslandMetrics.glyph + IslandMetrics.glyphSpacing
        let all = Int((width + IslandMetrics.glyphSpacing) / step)
        if count <= all { return count }
        let chip = IslandMetrics.overflowChipWidth(count) + IslandMetrics.glyphSpacing
        return max(0, Int((width - chip + IslandMetrics.glyphSpacing) / step))
    }

    static func width(_ size: WidgetSize, dashboardWidth: CGFloat = DashboardLayout.width) -> CGFloat {
        let slot = DashboardLayout.slotWidth(forWidth: dashboardWidth)
        let n = min(size.columns, DashboardLayout.columns(forWidth: dashboardWidth))
        return CGFloat(n) * slot + CGFloat(n - 1) * DashboardLayout.spacing
    }

    var body: some View {
        let s = model.settings
        let items = s.visibleDashboard
        let rows = DashboardLayout.rows(items, columns: model.dashboardColumns)
        let dashboardWidth = model.dashboardWidth
        let cardRadius = max(12, model.radius - 14)
        VStack(spacing: 0) {
            EarRow(model: model) {
                if s[module: .backgroundApps].enabled {
                    let excluded = Set(s.backgroundApps.excludedBundleIDs)
                    let apps = env.backgroundApps.apps.filter { !excluded.contains($0.bundleID ?? "") }
                    let fit = Self.iconsThatFit(apps.count, in: model.earContentWidth)
                    // One button: the icons and "+N" open the Open apps grid.
                    Button { model.open("backgroundApps") } label: {
                        HStack(spacing: IslandMetrics.glyphSpacing) {
                            AppIconRow(apps: Array(apps.prefix(fit)), size: 20, activates: false)
                            if apps.count > fit { OverflowChip(count: apps.count - fit) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(env.engine.activity(id: "backgroundApps") == nil)
                    .help("Show open apps")
                    .accessibilityLabel("Open apps, \(apps.count)")
                }
            } trailing: {
                if env.battery.info.hasBattery {
                    if s.battery.showPercent { Text("\(env.battery.info.percent)%").monospacedDigit() }
                    // Filled to the real charge (it was a fixed three-quarters symbol).
                    BatteryGlyph(percent: env.battery.info.percent, charging: env.battery.info.isCharging)
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
                                    .frame(width: Self.width(item.size, dashboardWidth: dashboardWidth), height: DashboardLayout.cardHeight)
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

/// The processor and the graphics: both readings side by side with a colour
/// key, over one graph where their lines share a scale. Over 80% turns red.
private struct CPUWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let stats = env.systemStats
        let cpuColor: Color = stats.cpu > 0.8 ? .red : .blue
        let gpuColor: Color = (stats.gpu ?? 0) > 0.8 ? .red : .purple
        HStack(alignment: .top, spacing: size == .medium ? 28 : 18) {
            reading(stats.cpu, label: "CPU", key: .blue)
            if let gpu = stats.gpu { reading(gpu, label: "GPU", key: .purple) }
            if size == .medium {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(ProcessInfo.processInfo.activeProcessorCount)-core CPU")
                    if let cores = stats.gpuCores {
                        Text("\(cores)-core GPU" + (stats.gpuMemoryUsed.map { " · \(ByteFormat.memory($0))" } ?? ""))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 4)
        ZStack {
            Sparkline(values: stats.cpuHistory, maxValue: 1, color: cpuColor, fill: stats.gpu == nil)
            if stats.gpu != nil {
                Sparkline(values: stats.gpuHistory, maxValue: 1, color: gpuColor, baseline: false)
            }
        }
        .frame(height: size == .medium ? 54 : 50)
    }

    private func reading(_ value: Double, label: String, key: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(value > 0.8 ? .red : .primary)
                .contentTransition(.numericText())
                .lineLimit(1).fixedSize()
            HStack(spacing: 4) {
                Circle().fill(key).frame(width: 6, height: 6)
                Text(label)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
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
    /// Off for a second line drawn over another graph, which has one already.
    var baseline = true

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                // A faint baseline across the full width, so a history that is
                // still filling in doesn't look cut off.
                if baseline {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height - 0.5))
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 0.5))
                    }
                    .stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
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
