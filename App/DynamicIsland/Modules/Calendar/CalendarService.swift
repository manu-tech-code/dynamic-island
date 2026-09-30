import AppKit
import EventKit
import IslandCore
import Observation

/// Upcoming events from EventKit. An event joins the island a few minutes
/// before it starts and leaves 15 minutes in (or when it ends, if sooner).
@Observable
final class CalendarService: ActivityProvider {
    enum Access: Equatable { case notDetermined, granted, denied }

    let kind = ActivityKind.calendar
    private(set) var access: Access = .notDetermined
    /// Timed (not all-day) events that haven't ended, from now to the end of tomorrow.
    private(set) var upcoming: [CalendarEventInfo] = []
    /// Bumped at every time boundary so `activities` recomputes.
    private var tick = 0

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    @ObservationIgnored private var alerted: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    static let lingerAfterStart: TimeInterval = 15 * 60

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        access = Self.currentAccess()
    }

    var activities: [Activity] {
        _ = tick
        let now = Date()
        let lead = TimeInterval(settings.settings.calendar.leadMinutes * 60)
        guard let event = upcoming.first(where: { e in
            e.start.addingTimeInterval(-lead) <= now && now < min(e.end, e.start.addingTimeInterval(Self.lingerAfterStart))
        }) else { return [] }
        // An event that has started outranks one that's only coming up.
        return [Activity(id: "event-\(event.id)", kind: .calendar, payload: .calendar(event),
                         relevance: event.isInProgress(at: now) ? 1 : 0.6, startedAt: event.start)]
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        if access == .notDetermined, settings.settings[module: .calendar].enabled {
            requestAccess()
        } else {
            reload()
        }
    }

    func requestAccess() {
        Task {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                Log.error("calendar access request failed: \(error)")
            }
            access = Self.currentAccess()
            Log.info("calendar access: \(access)")
            reload()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInCalendar(_ event: CalendarEventInfo) {
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private func reload() {
        access = Self.currentAccess()
        guard access == .granted else { upcoming = []; return }
        let now = Date()
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(172_800)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.lingerAfterStart), end: end, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
            .map(Self.info(from:))
        scheduleBoundary()
    }

    static func info(from e: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(
            id: e.calendarItemIdentifier + "-\(Int(e.startDate.timeIntervalSince1970))",
            title: e.title?.isEmpty == false ? e.title! : "Untitled event",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            calendarColorHex: NSColor(cgColor: e.calendar?.cgColor ?? NSColor.systemBlue.cgColor)?.hexString ?? "#0A84FF",
            location: e.location, joinURL: MeetingLinks.joinURL(url: e.url, location: e.location, notes: e.notes))
    }

    /// Sleeps until the next moment the island's calendar content can change.
    private func scheduleBoundary() {
        boundaryTask?.cancel()
        let now = Date()
        let lead = TimeInterval(settings.settings.calendar.leadMinutes * 60)
        let boundaries = upcoming.flatMap { e in
            [e.start.addingTimeInterval(-lead), e.start, e.start.addingTimeInterval(Self.lingerAfterStart), e.end]
        }.filter { $0 > now }
        guard let next = boundaries.min() else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.tick += 1
            self.alertIfStarting()
            self.reload()
        }
    }

    private func alertIfStarting() {
        guard settings.settings.calendar.alertAtStart else { return }
        let now = Date()
        for e in upcoming where abs(e.start.timeIntervalSince(now)) < 60 && !alerted.contains(e.id) {
            alerted.insert(e.id)
            engine.post(IslandAlert(kind: .calendar, style: .eventStarting(e), holdSeconds: 6))
        }
    }
}

extension NSColor {
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
