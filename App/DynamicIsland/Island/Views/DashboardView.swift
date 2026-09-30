import IslandCore
import SwiftUI

/// Opens from an idle island, the activity row, or ⌥⌘I. Background apps sit
/// beside the camera; cards for each enabled module fill the body.
struct DashboardView: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let s = model.settings
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
                IslandIconButton(systemName: "gearshape.fill", size: 24, label: "Settings") { env.openSettings() }
            }
            HStack(spacing: 10) {
                if s[module: .nowPlaying].enabled { NowPlayingCard().layoutPriority(1) }
                if s[module: .calendar].enabled { CalendarCard() }
                if s[module: .timer].enabled { TimerCard() }
                if s[module: .battery].enabled { BatteryCard() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct NowPlayingCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        IslandCard(title: "Now Playing") {
            if let info = np.info {
                HStack(spacing: 10) {
                    ArtworkView(image: np.artwork, size: 46, radius: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(info.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 1 : 3600)) { ctx in
                    ProgressTrack(fraction: info.progress(at: ctx.date) ?? 0, height: 4)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                HStack {
                    IslandIconButton(systemName: "backward.fill", size: 30, label: "Previous track") { np.previous() }
                    Spacer()
                    IslandIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: 36, label: info.isPlaying ? "Pause" : "Play") { np.togglePlayPause() }
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    IslandIconButton(systemName: "forward.fill", size: 30, label: "Next track") { np.next() }
                }
            } else {
                Spacer(minLength: 0)
                Label(np.source == .unavailable ? "Now Playing unavailable" : "Nothing playing", systemImage: "music.note")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CalendarCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cal = env.calendar
        IslandCard(title: Date().formatted(.dateTime.weekday(.abbreviated).day())) {
            switch cal.access {
            case .granted:
                TimelineView(.everyMinute) { ctx in
                    let events = Array(cal.upcoming.filter { $0.end > ctx.date }.prefix(2))
                    if events.isEmpty {
                        Text("No more events today or tomorrow").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(events) { e in EventRow(event: e, now: ctx.date) }
                        }
                        Spacer(minLength: 0)
                        if let url = events.first?.joinURL, events.first!.start.timeIntervalSince(ctx.date) < 30 * 60 {
                            IslandCapsuleButton(title: "Join", systemName: "video.fill", prominent: true) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            case .notDetermined:
                Text("See your next event here.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                IslandCapsuleButton(title: "Allow access", prominent: true) { cal.requestAccess() }
            case .denied:
                Text("Calendar access is off.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                IslandCapsuleButton(title: "Open Privacy Settings") { cal.openPrivacySettings() }
            }
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
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var detail: String {
        let time = event.start.formatted(date: Calendar.current.isDateInToday(event.start) ? .omitted : .abbreviated, time: .shortened)
        return event.isInProgress(at: now) ? "\(time) · now" : "\(time) · \(IslandFormat.untilLong(event.start, from: now))"
    }
}

private struct TimerCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let timers = env.timers
        IslandCard(title: "Timer") {
            if let t = timers.running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 6) {
                        Ring(fraction: t.fractionRemaining(at: ctx.date), color: .orange, lineWidth: 5)
                            .frame(width: 66, height: 66)
                            .overlay(Text(IslandFormat.countdown(t.remaining(at: ctx.date))).font(.system(size: 13, weight: .semibold)).monospacedDigit())
                        Text(t.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                HStack {
                    IslandIconButton(systemName: t.isRunning ? "pause.fill" : "play.fill", size: 28, label: t.isRunning ? "Pause" : "Resume") {
                        t.isRunning ? timers.pause(t.id) : timers.resume(t.id)
                    }
                    Spacer()
                    IslandIconButton(systemName: "xmark", size: 28, label: "Cancel timer") { timers.cancel(t.id) }
                }
            } else {
                let presets = env.settings.settings.timers.presetMinutes
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(presets, id: \.self) { m in
                        IslandCapsuleButton(title: m >= 60 && m % 60 == 0 ? "\(m / 60) h" : "\(m) min") { timers.start(minutes: Double(m)) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct BatteryCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let b = env.battery.info
        IslandCard(title: "Battery") {
            BatteryRing(info: b, size: 56).frame(maxWidth: .infinity).padding(.top, 2)
            Spacer(minLength: 0)
            Text(BatteryText.headline(b)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(BatteryText.detail(b)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
