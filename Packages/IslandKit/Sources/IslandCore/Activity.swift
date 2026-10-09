import Foundation

/// The kinds of live activity the island can show. Order here is only the
/// fallback; the user's priority list decides which one wins the island.
public enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case nowPlaying, timer, calendar, battery, backgroundApps
    case shelf, downloads, privacy, devices, hud
    /// Messages from any app, read from macOS's notification banners.
    case messages
    /// AI coding agents at work (Claude Code, Codex…), read from their own files.
    case agents

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .timer: "Timers"
        case .calendar: "Calendar"
        case .battery: "Battery"
        case .backgroundApps: "Background apps"
        case .shelf: "Shelf"
        case .downloads: "Downloads"
        case .privacy: "Mic and camera"
        case .devices: "AirPods and Bluetooth"
        case .hud: "Volume and brightness"
        case .messages: "Messages"
        case .agents: "AI agents"
        }
    }

    public var symbolName: String {
        switch self {
        case .nowPlaying: "music.note"
        case .timer: "timer"
        case .calendar: "calendar"
        case .battery: "battery.75percent"
        case .backgroundApps: "square.grid.2x2"
        case .shelf: "tray.full"
        case .downloads: "arrow.down.circle"
        case .privacy: "mic.fill"
        case .devices: "airpodspro"
        case .hud: "speaker.wave.2.fill"
        case .messages: "message.fill"
        case .agents: "sparkles"
        }
    }

    /// Kinds that can sit on the compact island. The others only raise alerts
    /// (devices) or HUDs (volume and brightness).
    public var canBeLive: Bool { self != .devices && self != .hud }

    /// Defaults for a module the user hasn't touched. The HUD needs
    /// Accessibility, so it starts off.
    public var defaultModule: ModuleSettings {
        switch self {
        case .hud: ModuleSettings(enabled: false, showInCompact: false)
        case .devices: ModuleSettings(enabled: true, showInCompact: false)
        default: ModuleSettings()
        }
    }

    /// Kinds added after people had saved their priority lists, and the kind
    /// each goes after in an older list.
    public static let addedAfter: [ActivityKind: ActivityKind] = [.messages: .timer, .agents: .timer]

    public static let defaultPriority: [ActivityKind] = [
        .calendar, .nowPlaying, .timer, .agents, .messages, .downloads, .privacy, .battery, .shelf, .backgroundApps,
    ]
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

public enum ShelfItemKind: String, Codable, Sendable {
    case file, folder, image, text, link
}

/// Something kept on the shelf. Files are referenced by path (and bookmark,
/// in the app); text, links and images dropped in are saved as files.
public struct ShelfItemInfo: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ShelfItemKind
    public var path: String
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, kind: ShelfItemKind, path: String, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.path = path; self.addedAt = addedAt
    }

    /// The external drive the item is on ("/Volumes/Backup"), nil on the startup disk.
    /// While that drive isn't connected, the item waits on the shelf instead of leaving it.
    public var volume: String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }
}

public struct DownloadInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// 0…1 when the browser reports it.
    public var fraction: Double?
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var startedAt: Date

    public init(id: String, name: String, fraction: Double? = nil, completedBytes: Int64? = nil, totalBytes: Int64? = nil, startedAt: Date = Date()) {
        self.id = id; self.name = name; self.fraction = fraction
        self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.startedAt = startedAt
    }
}

public struct PrivacyInfo: Equatable, Sendable {
    public var microphone: Bool
    public var camera: Bool

    public init(microphone: Bool, camera: Bool) {
        self.microphone = microphone; self.camera = camera
    }
}

public enum BluetoothDeviceKind: String, Codable, Sendable {
    case airpods, airpodsPro, airpodsMax, beats, earbuds, headphones, speaker, keyboard, mouse, trackpad, gameController, other

    public var symbolName: String {
        switch self {
        case .airpods: "airpods"
        case .airpodsPro: "airpodspro"
        case .airpodsMax: "airpodsmax"
        case .beats: "beats.headphones"
        case .earbuds: "earbuds"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    public var isAudio: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax, .beats, .earbuds, .headphones, .speaker: true
        default: false
        }
    }

    /// Bluetooth class of device values (the Assigned Numbers spec).
    public static let majorAudio: UInt32 = 0x04
    public static let majorPeripheral: UInt32 = 0x05
    static let minorHeadphones: UInt32 = 0x06
    static let speakerMinors: Set<UInt32> = [0x05, 0x07, 0x0A] // loudspeaker, portable, hi-fi

    /// Any maker's device. Names come first (many devices report no useful
    /// class, and a soundbar can call itself a "headset"), then the class.
    public static func classify(name: String, majorClass: UInt32, minorClass: UInt32) -> BluetoothDeviceKind {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("airpods max") { return .airpodsMax }
        if has("airpods pro") { return .airpodsPro }
        if has("airpods") { return .airpods }
        if has("beats", "powerbeats") { return .beats }
        if has("keyboard") { return .keyboard }
        if has("trackpad") { return .trackpad }
        if has("mouse") { return .mouse }
        if has("controller", "dualsense", "xbox") { return .gameController }
        // Galaxy Buds, oraimo FreePods and SpaceBuds, Pixel Buds, Huawei FreeBuds, Sony WF-…, TWS…
        if has("buds", "pods", "tws", "earbud", "earphone", "wf-", "freeclip", "in-ear") { return .earbuds }
        if has("speaker", "boom", "soundlink", "soundbar", "flip", "charge") { return .speaker }
        switch majorClass {
        case majorAudio:
            if speakerMinors.contains(minorClass) { return .speaker }
            return .headphones
        default:
            return .other
        }
    }
}

/// Battery levels from macOS's own Bluetooth report (`system_profiler
/// SPBluetoothDataType -json`), which includes other makers' earbuds and
/// headphones that send their level. Keyed by address, "aa:bb:cc:dd:ee:ff".
public enum BluetoothBatteryReport {
    public struct Levels: Equatable, Sendable {
        public var main: Int?, left: Int?, right: Int?, `case`: Int?
        public init(main: Int? = nil, left: Int? = nil, right: Int? = nil, case: Int? = nil) {
            self.main = main; self.left = left; self.right = right; self.case = `case`
        }
        public var isEmpty: Bool { main == nil && left == nil && right == nil && `case` == nil }
    }

    /// IOBluetooth writes "82-06-20-00-16-cd"; the report writes "82:06:20:00:16:CD".
    public static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    public static func parse(_ data: Data) -> [String: Levels] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        func percent(_ value: Any?) -> Int? {
            guard let s = value as? String, let v = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
                  (1...100).contains(v) else { return nil }
            return v
        }
        var result: [String: Levels] = [:]
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for case let props as [String: Any] in entry.values {
                    guard let address = props["device_address"] as? String else { continue }
                    let levels = Levels(main: percent(props["device_batteryLevelMain"] ?? props["device_batteryLevel"]),
                                        left: percent(props["device_batteryLevelLeft"]),
                                        right: percent(props["device_batteryLevelRight"]),
                                        case: percent(props["device_batteryLevelCase"]))
                    if !levels.isEmpty { result[normalize(address)] = levels }
                }
            }
        }
        return result
    }
}

public struct BluetoothDeviceInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: BluetoothDeviceKind
    /// Battery percentages where the device reports them (AirPods report three).
    public var battery: Int?
    public var batteryLeft: Int?
    public var batteryRight: Int?
    public var batteryCase: Int?

    public init(id: String, name: String, kind: BluetoothDeviceKind, battery: Int? = nil,
                batteryLeft: Int? = nil, batteryRight: Int? = nil, batteryCase: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.battery = battery
        self.batteryLeft = batteryLeft; self.batteryRight = batteryRight; self.batteryCase = batteryCase
    }

    public var hasBattery: Bool { battery != nil || batteryLeft != nil || batteryRight != nil || batteryCase != nil }

    /// The level a single ring shows: the lower earbud for AirPods (as on
    /// iPhone), else the device's own battery, else the case.
    public var ringPercent: Int? {
        [batteryLeft, batteryRight].compactMap { $0 }.min() ?? battery ?? batteryCase
    }
}

public enum ActivityPayload: Equatable, Sendable {
    case nowPlaying(NowPlayingInfo)
    case timer(TimerInfo)
    case calendar(CalendarEventInfo)
    case battery(BatteryInfo)
    case backgroundApps([RunningAppInfo])
    case shelf([ShelfItemInfo])
    case download(DownloadInfo)
    case privacy(PrivacyInfo)
    /// Unread messages, per app (the badges style).
    case messages([UnreadApp])
    /// AI agents working now, the longest-running first.
    case agents([AgentSession])
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
        case deviceConnected(BluetoothDeviceInfo)
        case deviceDisconnected(name: String, kind: BluetoothDeviceKind)
        case downloadFinished(name: String, path: String)
        case volume(level: Double, muted: Bool, output: String)
        case brightness(level: Double)
        /// A general note, e.g. the first-run tip.
        case message(title: String, subtitle: String, symbol: String)
        /// A newer version was found by the daily check; Install opens Sparkle.
        case updateAvailable(version: String)
        /// Messages from another app, newest first, in the style chosen in Settings.
        case messages([MessageInfo], MessageAlertStyle)
        /// An AI agent finished and waits for you, or stopped to ask you something.
        case agentFinished(AgentFinish)
    }

    /// Status alerts show like a compact activity (an icon on the left, a ring on
    /// the right) instead of a card. Ones with a button stay cards.
    public var isCompact: Bool {
        switch style {
        case .deviceConnected, .deviceDisconnected, .chargerConnected, .chargerDisconnected, .lowBattery: true
        case .messages(_, let style): style.isCompact
        default: false
        }
    }

    /// HUDs update in place while a key is held, instead of queueing.
    public var isHUD: Bool {
        switch style {
        case .volume, .brightness: true
        default: false
        }
    }

    public var id: UUID
    public var kind: ActivityKind
    public var style: Style
    public var holdSeconds: TimeInterval

    public init(id: UUID = UUID(), kind: ActivityKind, style: Style, holdSeconds: TimeInterval = 2.5) {
        self.id = id; self.kind = kind; self.style = style; self.holdSeconds = holdSeconds
    }
}
