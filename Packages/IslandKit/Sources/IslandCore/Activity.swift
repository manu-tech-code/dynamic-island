import Foundation

/// The kinds of live activity the island can show. Order here is only the
/// fallback; the user's priority list decides which one wins the island.
public enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case nowPlaying, timer, calendar, battery, backgroundApps

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .timer: "Timers"
        case .calendar: "Calendar"
        case .battery: "Battery"
        case .backgroundApps: "Background apps"
        }
    }

    public var symbolName: String {
        switch self {
        case .nowPlaying: "music.note"
        case .timer: "timer"
        case .calendar: "calendar"
        case .battery: "battery.75percent"
        case .backgroundApps: "square.grid.2x2"
        }
    }
}

public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval?
    /// Elapsed time reported at `timestamp`; advance it with `playbackRate`.
    public var elapsedAtTimestamp: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Changes whenever the artwork changes, so views can cache decoded images.
    public var artworkKey: String?
    public var sourcePID: Int32?

    public init(title: String, artist: String = "", album: String = "", duration: TimeInterval? = nil,
                elapsedAtTimestamp: TimeInterval? = nil, timestamp: Date? = nil, playbackRate: Double = 0,
                isPlaying: Bool = false, artworkKey: String? = nil, sourcePID: Int32? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.elapsedAtTimestamp = elapsedAtTimestamp; self.timestamp = timestamp; self.playbackRate = playbackRate
        self.isPlaying = isPlaying; self.artworkKey = artworkKey; self.sourcePID = sourcePID
    }

    /// Current playback position, clamped to `0...duration`.
    public func elapsed(at now: Date) -> TimeInterval? {
        guard let base = elapsedAtTimestamp else { return nil }
        var value = base
        if isPlaying, let ts = timestamp { value += now.timeIntervalSince(ts) * (playbackRate == 0 ? 1 : playbackRate) }
        value = max(0, value)
        if let d = duration, d > 0 { value = min(value, d) }
        return value
    }

    public func progress(at now: Date) -> Double? {
        guard let d = duration, d > 0, let e = elapsed(at: now) else { return nil }
        return e / d
    }
}

public struct TimerInfo: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var label: String
    public var duration: TimeInterval
    /// Set while running.
    public var endDate: Date?
    /// Set while paused.
    public var pausedRemaining: TimeInterval?
    public var createdAt: Date

    public init(id: UUID = UUID(), label: String, duration: TimeInterval, endDate: Date?, pausedRemaining: TimeInterval? = nil, createdAt: Date = Date()) {
        self.id = id; self.label = label; self.duration = duration
        self.endDate = endDate; self.pausedRemaining = pausedRemaining; self.createdAt = createdAt
    }

    public var isRunning: Bool { endDate != nil }
    public var isPaused: Bool { endDate == nil && pausedRemaining != nil }

    public func remaining(at now: Date) -> TimeInterval {
        if let end = endDate { return max(0, end.timeIntervalSince(now)) }
        return max(0, pausedRemaining ?? duration)
    }

    /// Fraction of the timer still to go, 1 → 0.
    public func fractionRemaining(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, remaining(at: now) / duration)
    }

    public func isFinished(at now: Date) -> Bool { isRunning && remaining(at: now) <= 0 }
}

public struct BatteryInfo: Equatable, Sendable {
    public var hasBattery: Bool
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    /// Minutes to empty (on battery) or to full (charging), when the system knows.
    public var minutesRemaining: Int?

    public init(hasBattery: Bool, percent: Int, isCharging: Bool, isPluggedIn: Bool, minutesRemaining: Int? = nil) {
        self.hasBattery = hasBattery; self.percent = percent; self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn; self.minutesRemaining = minutesRemaining
    }
}

public struct CalendarEventInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarColorHex: String
    public var location: String?
    public var joinURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                calendarColorHex: String = "#0A84FF", location: String? = nil, joinURL: URL? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.calendarColorHex = calendarColorHex; self.location = location; self.joinURL = joinURL
    }

    public func isInProgress(at now: Date) -> Bool { start <= now && now < end }
}

public struct RunningAppInfo: Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var id: String { bundleID ?? "pid-\(pid)" }

    public init(pid: Int32, bundleID: String?, name: String) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
    }
}

public enum ActivityPayload: Equatable, Sendable {
    case nowPlaying(NowPlayingInfo)
    case timer(TimerInfo)
    case calendar(CalendarEventInfo)
    case battery(BatteryInfo)
    case backgroundApps([RunningAppInfo])
}

/// Something live that competes for space on the island.
public struct Activity: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ActivityKind
    public var payload: ActivityPayload
    /// Tie-breaker within a kind, higher wins (Apple's relevanceScore idea).
    public var relevance: Double
    public var startedAt: Date

    public init(id: String, kind: ActivityKind, payload: ActivityPayload, relevance: Double = 0.5, startedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.payload = payload; self.relevance = relevance; self.startedAt = startedAt
    }
}

/// A brief moment that grows the island, holds, then retracts.
public struct IslandAlert: Identifiable, Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case chargerConnected(percent: Int)
        case chargerDisconnected(percent: Int)
        case lowBattery(percent: Int)
        case timerFinished(label: String)
        case eventStarting(CalendarEventInfo)
    }

    public var id: UUID
    public var kind: ActivityKind
    public var style: Style
    public var holdSeconds: TimeInterval

    public init(id: UUID = UUID(), kind: ActivityKind, style: Style, holdSeconds: TimeInterval = 2.5) {
        self.id = id; self.kind = kind; self.style = style; self.holdSeconds = holdSeconds
    }
}
