import AppKit
import IslandCore
import Observation

/// Countdown timers. Running timers survive a relaunch because they are stored
/// by end date, not by remaining time.
@Observable
final class TimerService: ActivityProvider {
    let kind = ActivityKind.timer
    private(set) var timers: [TimerInfo] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private let storeKey = "timers.v1"

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([TimerInfo].self, from: data) {
            timers = saved
        }
        checkFinished()
    }

    var activities: [Activity] {
        let now = Date()
        return timers.map { t in
            // Sooner-ending timers are more relevant.
            let relevance = t.isRunning ? 1 / (1 + t.remaining(at: now) / 60) : 0.1
            return Activity(id: "timer-\(t.id)", kind: .timer, payload: .timer(t), relevance: relevance, startedAt: t.createdAt)
        }
    }

    var running: TimerInfo? { timers.first(where: \.isRunning) ?? timers.first }

    // MARK: actions

    @discardableResult
    func start(minutes: Double, label: String? = nil) -> TimerInfo {
        let seconds = minutes * 60
        let t = TimerInfo(label: label ?? Self.defaultLabel(minutes: minutes), duration: seconds, endDate: Date().addingTimeInterval(seconds))
        timers.append(t)
        changed()
        return t
    }

    func pause(_ id: UUID) {
        update(id) { t in
            t.pausedRemaining = t.remaining(at: Date())
            t.endDate = nil
        }
    }

    func resume(_ id: UUID) {
        update(id) { t in
            t.endDate = Date().addingTimeInterval(t.pausedRemaining ?? t.duration)
            t.pausedRemaining = nil
        }
    }

    func addMinute(_ id: UUID) {
        update(id) { t in
            t.duration += 60
            if let end = t.endDate { t.endDate = end.addingTimeInterval(60) }
            if let p = t.pausedRemaining { t.pausedRemaining = p + 60 }
        }
    }

    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        changed()
    }

    static func defaultLabel(minutes: Double) -> String {
        minutes >= 60 && minutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(minutes / 60)) h timer" : "\(Int(minutes)) min timer"
    }

    // MARK: internals

    private func update(_ id: UUID, _ body: (inout TimerInfo) -> Void) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        body(&timers[i])
        changed()
    }

    private func changed() {
        if let data = try? JSONEncoder().encode(timers) { UserDefaults.standard.set(data, forKey: storeKey) }
        scheduleFinish()
    }

    /// One task sleeping until the earliest end date, instead of a ticking timer.
    private func scheduleFinish() {
        finishTask?.cancel()
        guard let next = timers.compactMap(\.endDate).min() else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.checkFinished()
        }
    }

    private func checkFinished() {
        let now = Date()
        let done = timers.filter { $0.isFinished(at: now) }
        guard !done.isEmpty else { scheduleFinish(); return }
        timers.removeAll { t in done.contains { $0.id == t.id } }
        for t in done {
            Log.info("timer finished: \(t.label)")
            engine.post(IslandAlert(kind: .timer, style: .timerFinished(label: t.label), holdSeconds: 4))
        }
        if settings.settings.timers.playSound { NSSound(named: "Glass")?.play() }
        changed()
    }
}
