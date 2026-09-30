import Foundation

public enum DisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Only the built-in display with a hardware notch.
    case builtIn
    /// Every display; displays without a notch get a virtual one.
    case all

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .builtIn: "Built-in display"
        case .all: "All displays (virtual notch)"
        }
    }
}

public struct ModuleSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// When false the module only appears in the dashboard and in alerts.
    public var showInCompact: Bool

    public init(enabled: Bool = true, showInCompact: Bool = true) {
        self.enabled = enabled; self.showInCompact = showInCompact
    }
}

public struct NowPlayingSettings: Codable, Equatable, Sendable {
    /// Keep a paused track on the island for this long before it leaves.
    public var keepPausedMinutes: Int = 3
    public init() {}
}

public struct BackgroundAppsSettings: Codable, Equatable, Sendable {
    /// Icons shown on the compact island; the rest collapse into "+N".
    public var maxIcons: Int = 4
    public var excludedBundleIDs: [String] = ["com.apple.finder"]
    public init() {}
}

public struct CalendarSettings: Codable, Equatable, Sendable {
    /// An upcoming event joins the island this many minutes before it starts.
    public var leadMinutes: Int = 15
    public var alertAtStart: Bool = true
    public init() {}
}

public struct TimerSettings: Codable, Equatable, Sendable {
    public var presetMinutes: [Int] = [1, 5, 10, 25, 60]
    public var playSound: Bool = true
    public init() {}
}

public struct BatterySettings: Codable, Equatable, Sendable {
    public var alertOnPower: Bool = true
    public var lowBatteryPercents: [Int] = [20, 10]
    public init() {}
}

/// Everything the user can configure. Stored as JSON; unknown or missing keys
/// fall back to defaults so older files keep working as fields are added.
public struct IslandSettings: Codable, Equatable, Sendable {
    public var material: IslandMaterial = .hybrid
    public var compactStyle: CompactStyle = .beside
    /// How many live activities share the compact island. 0 means unlimited.
    public var maxActivities: Int = 3
    public var priority: [ActivityKind] = [.calendar, .nowPlaying, .timer, .battery, .backgroundApps]
    public var openOnHover: Bool = false
    public var hoverDelayMs: Int = 150
    public var collapseOnMouseLeave: Bool = true
    public var glowFromArtwork: Bool = true
    public var displays: DisplayMode = .builtIn
    public var showMenuBarIcon: Bool = true

    public var nowPlayingModule = ModuleSettings()
    public var timerModule = ModuleSettings()
    public var calendarModule = ModuleSettings()
    public var batteryModule = ModuleSettings(enabled: true, showInCompact: true)
    public var backgroundAppsModule = ModuleSettings()

    public var nowPlaying = NowPlayingSettings()
    public var backgroundApps = BackgroundAppsSettings()
    public var calendar = CalendarSettings()
    public var timers = TimerSettings()
    public var battery = BatterySettings()

    public init() {}

    public static let maxActivitiesRange = 0...12

    public var activityLimit: Int? { maxActivities <= 0 ? nil : maxActivities }

    public subscript(module kind: ActivityKind) -> ModuleSettings {
        get {
            switch kind {
            case .nowPlaying: nowPlayingModule
            case .timer: timerModule
            case .calendar: calendarModule
            case .battery: batteryModule
            case .backgroundApps: backgroundAppsModule
            }
        }
        set {
            switch kind {
            case .nowPlaying: nowPlayingModule = newValue
            case .timer: timerModule = newValue
            case .calendar: calendarModule = newValue
            case .battery: batteryModule = newValue
            case .backgroundApps: backgroundAppsModule = newValue
            }
        }
    }

    public var compactKinds: Set<ActivityKind> {
        Set(ActivityKind.allCases.filter { self[module: $0].enabled && self[module: $0].showInCompact })
    }

    /// Clamps values and repairs the priority list (every kind exactly once).
    public func normalized() -> IslandSettings {
        var s = self
        s.maxActivities = min(max(s.maxActivities, Self.maxActivitiesRange.lowerBound), Self.maxActivitiesRange.upperBound)
        s.hoverDelayMs = min(max(s.hoverDelayMs, 0), 1500)
        s.backgroundApps.maxIcons = min(max(s.backgroundApps.maxIcons, 1), 24)
        s.calendar.leadMinutes = min(max(s.calendar.leadMinutes, 0), 120)
        s.nowPlaying.keepPausedMinutes = min(max(s.nowPlaying.keepPausedMinutes, 0), 120)
        var seen = Set<ActivityKind>()
        s.priority = s.priority.filter { seen.insert($0).inserted }
        for k in ActivityKind.allCases where !seen.contains(k) { s.priority.append(k) }
        s.timers.presetMinutes = Array(Set(s.timers.presetMinutes.filter { $0 > 0 && $0 <= 24 * 60 })).sorted()
        return s
    }

    // MARK: tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case material, compactStyle, maxActivities, priority, openOnHover, hoverDelayMs, collapseOnMouseLeave
        case glowFromArtwork, displays, showMenuBarIcon
        case nowPlayingModule, timerModule, calendarModule, batteryModule, backgroundAppsModule
        case nowPlaying, backgroundApps, calendar, timers, battery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IslandSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        material = v(.material, d.material)
        compactStyle = v(.compactStyle, d.compactStyle)
        maxActivities = v(.maxActivities, d.maxActivities)
        priority = ((try? c.decodeIfPresent([String].self, forKey: .priority)) ?? nil)
            .map { $0.compactMap(ActivityKind.init(rawValue:)) } ?? d.priority
        openOnHover = v(.openOnHover, d.openOnHover)
        hoverDelayMs = v(.hoverDelayMs, d.hoverDelayMs)
        collapseOnMouseLeave = v(.collapseOnMouseLeave, d.collapseOnMouseLeave)
        glowFromArtwork = v(.glowFromArtwork, d.glowFromArtwork)
        displays = v(.displays, d.displays)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        nowPlayingModule = v(.nowPlayingModule, d.nowPlayingModule)
        timerModule = v(.timerModule, d.timerModule)
        calendarModule = v(.calendarModule, d.calendarModule)
        batteryModule = v(.batteryModule, d.batteryModule)
        backgroundAppsModule = v(.backgroundAppsModule, d.backgroundAppsModule)
        nowPlaying = v(.nowPlaying, d.nowPlaying)
        backgroundApps = v(.backgroundApps, d.backgroundApps)
        calendar = v(.calendar, d.calendar)
        timers = v(.timers, d.timers)
        battery = v(.battery, d.battery)
        self = normalized()
    }

    public static func decode(_ data: Data) -> IslandSettings {
        (try? JSONDecoder().decode(IslandSettings.self, from: data)) ?? IslandSettings()
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

// Sub-settings decode tolerantly too, so a file missing one nested key keeps the rest.
extension NowPlayingSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepPausedMinutes = (try? c.decodeIfPresent(Int.self, forKey: .keepPausedMinutes)) ?? 3
    }
}
extension BackgroundAppsSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxIcons = (try? c.decodeIfPresent(Int.self, forKey: .maxIcons)) ?? 4
        excludedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)) ?? ["com.apple.finder"]
    }
}
extension CalendarSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leadMinutes = (try? c.decodeIfPresent(Int.self, forKey: .leadMinutes)) ?? 15
        alertAtStart = (try? c.decodeIfPresent(Bool.self, forKey: .alertAtStart)) ?? true
    }
}
extension TimerSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetMinutes = (try? c.decodeIfPresent([Int].self, forKey: .presetMinutes)) ?? [1, 5, 10, 25, 60]
        playSound = (try? c.decodeIfPresent(Bool.self, forKey: .playSound)) ?? true
    }
}
extension BatterySettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alertOnPower = (try? c.decodeIfPresent(Bool.self, forKey: .alertOnPower)) ?? true
        lowBatteryPercents = (try? c.decodeIfPresent([Int].self, forKey: .lowBatteryPercents)) ?? [20, 10]
    }
}
extension ModuleSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        showInCompact = (try? c.decodeIfPresent(Bool.self, forKey: .showInCompact)) ?? true
    }
}
