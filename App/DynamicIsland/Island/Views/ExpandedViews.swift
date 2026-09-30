import IslandCore
import SwiftUI

/// One activity, expanded. The top row sits beside the camera; the body below it.
struct ExpandedView: View {
    let activity: Activity
    let model: IslandViewModel

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch activity.payload {
        case .nowPlaying(let info): NowPlayingExpanded(info: info, model: model)
        case .timer(let t): TimerExpanded(timer: t, model: model)
        case .calendar(let e): CalendarExpanded(event: e, model: model)
        case .battery(let b): BatteryExpanded(info: b, model: model)
        case .backgroundApps(let apps): BackgroundAppsExpanded(apps: apps, model: model)
        case .shelf: ShelfView(model: model)
        case .download: DownloadsExpanded(model: model)
        case .privacy(let p): PrivacyExpanded(info: p, model: model)
        }
    }
}

/// Leading and trailing items beside the camera housing.
struct EarRow<Leading: View, Trailing: View>: View {
    let model: IslandViewModel
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading() }.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.rect.width + 2 * IslandMetrics.earInnerGap)
            HStack(spacing: 6) {
                trailing()
                // Open states other than the dashboard get a one-click way to it.
                if !model.isPreview, model.presentation != .dashboard, model.isOpen {
                    DashboardButton(model: model, size: 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: model.notch.rect.height)
        .modifier(EarForeground(material: model.material))
    }
}

// MARK: Timer

private struct TimerExpanded: View {
    let timer: TimerInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        EarRow(model: model) {
            Image(systemName: "timer").foregroundStyle(.orange)
            Text("Timer")
        } trailing: {
            Text(timer.label).lineLimit(1).foregroundStyle(.orange)
        }
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 16) {
                Ring(fraction: timer.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 5)
                    .frame(width: 62, height: 62)
                    .overlay(Image(systemName: timer.isRunning ? "timer" : "pause.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.orange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(IslandFormat.countdown(timer.remaining(at: ctx.date)))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(timer.isRunning ? "Ends at \(timer.endDate!.formatted(date: .omitted, time: .shortened))" : "Paused")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                IslandCapsuleButton(title: "+1 min") { env.timers.addMinute(timer.id) }
                IslandIconButton(systemName: timer.isRunning ? "pause.fill" : "play.fill", size: 36, label: timer.isRunning ? "Pause" : "Resume") {
                    timer.isRunning ? env.timers.pause(timer.id) : env.timers.resume(timer.id)
                }
                IslandIconButton(systemName: "xmark", size: 36, label: "Cancel timer") { env.timers.cancel(timer.id) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }
}

// MARK: Calendar

private struct CalendarExpanded: View {
    let event: CalendarEventInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let color = Color(hex: event.calendarColorHex)
        EarRow(model: model) {
            Image(systemName: "calendar").foregroundStyle(color)
            Text("Calendar")
        } trailing: {
            TimelineView(.everyMinute) { ctx in
                Text(IslandFormat.untilShort(event.start, from: ctx.date)).foregroundStyle(color)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(event.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            }
            TimelineView(.everyMinute) { ctx in
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.isInProgress(at: ctx.date) ? "in progress" : IslandFormat.untilLong(event.start, from: ctx.date))")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if let location = event.location, !location.isEmpty, event.joinURL?.absoluteString != location {
                Label(location, systemImage: "mappin.and.ellipse").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let url = event.joinURL {
                    IslandCapsuleButton(title: "Join", systemName: "video.fill", prominent: true) { NSWorkspace.shared.open(url) }
                }
                IslandCapsuleButton(title: "Open Calendar") { env.calendar.openInCalendar(event) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Battery

private struct BatteryExpanded: View {
    let info: BatteryInfo
    let model: IslandViewModel

    var body: some View {
        EarRow(model: model) {
            Image(systemName: "battery.25percent").foregroundStyle(.red)
            Text("Battery")
        } trailing: {
            Text("\(info.percent)%").monospacedDigit().foregroundStyle(.red)
        }
        HStack(spacing: 16) {
            BatteryRing(info: info, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(BatteryText.headline(info)).font(.system(size: 16, weight: .semibold))
                Text(BatteryText.detail(info)).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

struct BatteryRing: View {
    let info: BatteryInfo
    let size: CGFloat

    var body: some View {
        let color: Color = info.isPluggedIn ? .green : (info.percent <= 20 ? .red : .primary)
        Ring(fraction: Double(info.percent) / 100, color: color, lineWidth: size > 50 ? 5 : 4)
            .frame(width: size, height: size)
            .overlay {
                if info.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(info.percent)").font(.system(size: size * 0.3, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
    }
}

enum BatteryText {
    /// One or two words, for tight spaces.
    static func state(_ b: BatteryInfo) -> String {
        guard b.hasBattery else { return "Power adapter" }
        if b.isCharging { return "Charging" }
        if b.isPluggedIn { return "Plugged in" }
        return b.percent <= 20 ? "Low battery" : "On battery"
    }

    static func headline(_ b: BatteryInfo) -> String {
        guard b.hasBattery else { return "Power adapter" }
        if b.isCharging { return "Charging · \(b.percent)%" }
        if b.isPluggedIn { return "Plugged in · \(b.percent)%" }
        return b.percent <= 20 ? "Low battery · \(b.percent)%" : "On battery · \(b.percent)%"
    }

    static func detail(_ b: BatteryInfo) -> String {
        guard b.hasBattery else { return "No battery" }
        if let m = b.minutesRemaining {
            return b.isCharging ? "\(IslandFormat.duration(minutes: m)) to full" : "\(IslandFormat.duration(minutes: m)) left"
        }
        if b.isPluggedIn { return b.isCharging ? "Estimating time to full…" : "Not charging" }
        return "Estimating time left…"
    }
}

// MARK: Background apps

private struct BackgroundAppsExpanded: View {
    let apps: [RunningAppInfo]
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        EarRow(model: model) {
            Image(systemName: "square.grid.2x2.fill").foregroundStyle(.blue)
            Text("Open apps")
        } trailing: {
            Text("\(apps.count)").monospacedDigit()
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
            ForEach(apps.prefix(16)) { app in
                Button { env.backgroundApps.activate(app); model.collapse() } label: {
                    VStack(spacing: 3) {
                        AppIcon(app: app, size: 40)
                        Text(app.name).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}
