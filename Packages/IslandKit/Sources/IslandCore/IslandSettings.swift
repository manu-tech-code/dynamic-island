import Foundation

public enum DisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Only the built-in display with a hardware notch.
    case builtIn
    /// Whichever display has the menu bar (follows it when you change it).
    case menuBarDisplay
    /// Every display; displays without a notch get a virtual one.
    case all

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .builtIn: "Built-in display"
        case .menuBarDisplay: "Display with the menu bar"
        case .all: "All displays"
        }
    }
}

/// Whether the compact island shows a dashboard button at the end of its right ear.
public enum DashboardButtonMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case always, off
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .always: "Show"
        case .off: "Off"
        }
    }

    /// "onHover" was removed (it had to reserve empty room); it reads as `.always`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == Self.off.rawValue ? .off : .always
    }
}

/// When the compact island is out from under the notch.
public enum IslandVisibility: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whenever something is live (music, a timer, a call…).
    case always
    /// Tucked under the notch until the pointer reaches the camera.
    case onHover
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .always: "Always"
        case .onHover: "When the pointer is at the camera"
        }
    }
}

/// How a hidden island comes out from under the notch and tucks back in.
public enum RevealStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The ears slide out from under the camera, content riding the edges.
    case slide
    /// The edges spread first; the content fades and sharpens in once they've passed.
    case ink
    /// A springier stretch past full size, with the content popping up from small.
    case elastic
    /// The left ear opens a beat before the right, and closes after it.
    case curtain
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .slide: "Slide under the notch"
        case .ink: "Ink spread"
        case .elastic: "Elastic pop"
        case .curtain: "Curtain"
        }
    }
}

/// What stays out of a tucked island while a song plays (when the island
/// hides until hover). The pointer on it brings the whole island out.
public enum PlayingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Nothing: the island stays under the notch.
    case tucked
    /// Slim ears with only the artwork and the waveform.
    case slim
    /// The artwork in a bubble beside the notch, pulled out of it like a drop of water.
    case bubble
    /// The artwork in a bubble on the left, the waveform in one on the right.
    case twoBubbles
    /// The artwork in a drop hanging from the camera.
    case drip
    /// A record with the artwork as its label, peeking out and spinning.
    case record
    /// A glow in the artwork's colour under the notch, pulsing to the beat.
    case underglow
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .tucked: "Stay tucked"
        case .slim: "Artwork and waveform"
        case .bubble: "Bubble"
        case .twoBubbles: "Two bubbles"
        case .drip: "Drip"
        case .record: "Record"
        case .underglow: "Underglow"
        }
    }
}

/// What the island does while an app is full screen on its display.
public enum FullScreenBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Stay as usual.
    case show
    /// Hide unless something live is on it (music, a timer, a call) or an alert shows.
    case hideWhenIdle
    /// Hide; only alerts and the keyboard shortcut bring it back.
    case hide
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .show: "Keep showing"
        case .hideWhenIdle: "Hide unless something is live"
        case .hide: "Hide"
        }
    }
}

/// A keyboard shortcut in Carbon terms (virtual key code + modifier mask),
/// with the label shown in Settings.
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var carbonModifiers: Int
    public var label: String

    public init(keyCode: Int, carbonModifiers: Int, label: String) {
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers; self.label = label
    }

    /// ⌥⌘I: kVK_ANSI_I = 34, cmdKey | optionKey = 256 | 2048.
    public static let `default` = HotKeySpec(keyCode: 34, carbonModifiers: 256 | 2048, label: "⌥⌘I")
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
    /// Look up lyrics on LRCLIB when the lyrics page is opened. Only then are
    /// the track title, artist, album and length sent to lrclib.net.
    public var lyricsEnabled: Bool = true
    /// Show the next track under the artist.
    public var showUpNext: Bool = true
    /// Resting the pointer on the compact island shows the title and artist under it.
    public var titleOnHover: Bool = true
    /// A new song shows its title for a moment, the island coming out if it's tucked.
    public var titleOnTrackChange: Bool = true
    /// The waveform's bars follow the music (Core Audio tap; System Audio Recording permission).
    public var waveformFollowsAudio: Bool = true
    public init() {}
}

public struct SystemStatsSettings: Codable, Equatable, Sendable {
    /// Seconds between samples while the dashboard is open. Nothing is sampled while it's closed.
    public var refreshSeconds: Double = 1
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

public struct ShelfSettings: Codable, Equatable, Sendable {
    /// Open the shelf when a file is dragged toward the notch.
    public var openOnDrag: Bool = true
    /// How close to the top of the screen a drag must come, in points.
    public var dragActivationDistance: Double = 80
    public init() {}
}

public struct DownloadsSettings: Codable, Equatable, Sendable {
    public var alertWhenDone: Bool = true
    public init() {}
}

public struct DevicesSettings: Codable, Equatable, Sendable {
    /// Alert when headphones, speakers or other Bluetooth devices connect.
    public var alertOnConnect: Bool = true
    public var alertOnDisconnect: Bool = false
    public init() {}
}

public struct HUDSettings: Codable, Equatable, Sendable {
    /// Take over the volume and brightness keys so only the island's HUD
    /// shows. Needs Accessibility permission.
    public var replaceSystemHUD: Bool = true
    public var showVolume: Bool = true
    public var showBrightness: Bool = true
    /// Volume keys move in sixteenths, like macOS; ⌥⇧ gives quarter steps.
    public var steps: Int = 16
    public init() {}
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, celsius, fahrenheit
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }
}

public struct WeatherSettings: Codable, Equatable, Sendable {
    /// Use Location Services; otherwise `placeName` / coordinates below.
    public var useCurrentLocation: Bool = true
    public var placeName: String?
    public var latitude: Double?
    public var longitude: Double?
    public var unit: TemperatureUnit = .automatic
    public init() {}
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    /// Off until turned on: watching the clipboard is opt-in.
    public var enabled: Bool = false
    public var historySize: Int = 20
    /// Skip items that password managers mark as concealed or transient.
    public var ignoreConcealed: Bool = true
    public init() {}
}

public struct ShortcutsSettings: Codable, Equatable, Sendable {
    /// Shortcut names shown on the dashboard, in order.
    public var pinned: [String] = []
    public init() {}
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    public var showMicrophone: Bool = true
    public var showCamera: Bool = true
    public init() {}
}

/// Everything the user can configure. Stored as JSON; unknown or missing keys
/// fall back to defaults so older files keep working as fields are added.
public struct IslandSettings: Codable, Equatable, Sendable {
    public var material: IslandMaterial = .hybrid
    public var compactStyle: CompactStyle = .beside
    /// How many live activities share the compact island. 0 means unlimited.
    public var maxActivities: Int = 3
    public var priority: [ActivityKind] = ActivityKind.defaultPriority
    public var openOnHover: Bool = false
    public var hoverDelayMs: Int = 150
    public var collapseOnMouseLeave: Bool = true
    public var glowFromArtwork: Bool = true
    public var displays: DisplayMode = .builtIn
    public var showMenuBarIcon: Bool = true
    /// Width of the open island (expanded, dashboard, shelf), 0.75…1.35 × standard.
    public var openWidthScale: Double = 1
    /// Widest the compact island may get, in points; 0 means no limit. When
    /// content won't fit, background app icons and then extra activities leave it.
    public var compactMaxWidth: Double = 0
    public var dashboardButton: DashboardButtonMode = .always
    public var fullScreen: FullScreenBehavior = .hideWhenIdle
    /// Always out when something is live, or only while the pointer is at the camera.
    public var visibility: IslandVisibility = .always
    /// How the island comes out and tucks back in, when it hides until hover.
    public var revealStyle: RevealStyle = .slide
    /// What stays out while a song plays, when the island hides until hover.
    public var whilePlaying: PlayingStyle = .tucked
    /// On displays without a camera, draw the black virtual notch even when idle.
    public var virtualNotchWhenIdle: Bool = true
    /// The lock opening on the island when the Mac unlocks.
    public var lockIndicator: Bool = true
    public var hotKey: HotKeySpec = .default

    /// Per-module on/off and compact visibility, keyed by `ActivityKind.rawValue`.
    /// Missing entries use `ActivityKind.defaultModule`.
    public var modules: [String: ModuleSettings] = [:]

    public var nowPlaying = NowPlayingSettings()
    public var backgroundApps = BackgroundAppsSettings()
    public var calendar = CalendarSettings()
    public var timers = TimerSettings()
    public var battery = BatterySettings()
    public var systemStats = SystemStatsSettings()
    public var shelf = ShelfSettings()
    public var downloads = DownloadsSettings()
    public var devices = DevicesSettings()
    public var hud = HUDSettings()
    public var weather = WeatherSettings()
    public var clipboard = ClipboardSettings()
    public var shortcuts = ShortcutsSettings()
    public var privacy = PrivacySettings()
    public var dashboard: [DashboardItem] = DashboardItem.defaults

    public init() {}

    public static let maxActivitiesRange = 0...12
    public static let widthScaleRange = 0.75...1.35
    public static let compactMaxWidthRange = 300.0...900.0

    public var activityLimit: Int? { maxActivities <= 0 ? nil : maxActivities }

    public subscript(module kind: ActivityKind) -> ModuleSettings {
        get { modules[kind.rawValue] ?? kind.defaultModule }
        set { modules[kind.rawValue] = newValue }
    }

    /// Dashboard widgets whose module is on, in the user's order.
    public var visibleDashboard: [DashboardItem] {
        dashboard.filter { item in item.kind.module.map { self[module: $0].enabled } ?? true }
    }

    public var dashboardWidth: CGFloat { DashboardLayout.width(scale: openWidthScale) }
    public var dashboardColumns: Int { DashboardLayout.columns(forWidth: dashboardWidth) }
    public var dashboardRows: Int { max(1, DashboardLayout.rows(visibleDashboard, columns: dashboardColumns).count) }

    public var compactKinds: Set<ActivityKind> {
        Set(ActivityKind.allCases.filter { $0.canBeLive && self[module: $0].enabled && self[module: $0].showInCompact })
    }

    /// Clamps values and repairs the priority list (every live kind exactly once).
    public func normalized() -> IslandSettings {
        var s = self
        s.maxActivities = min(max(s.maxActivities, Self.maxActivitiesRange.lowerBound), Self.maxActivitiesRange.upperBound)
        s.hoverDelayMs = min(max(s.hoverDelayMs, 0), 1500)
        s.openWidthScale = min(max(s.openWidthScale, Self.widthScaleRange.lowerBound), Self.widthScaleRange.upperBound)
        if s.compactMaxWidth != 0 {
            s.compactMaxWidth = min(max(s.compactMaxWidth, Self.compactMaxWidthRange.lowerBound), Self.compactMaxWidthRange.upperBound)
        }
        s.backgroundApps.maxIcons = min(max(s.backgroundApps.maxIcons, 1), 24)
        s.calendar.leadMinutes = min(max(s.calendar.leadMinutes, 0), 120)
        s.nowPlaying.keepPausedMinutes = min(max(s.nowPlaying.keepPausedMinutes, 0), 120)
        s.clipboard.historySize = min(max(s.clipboard.historySize, 5), 100)
        s.hud.steps = min(max(s.hud.steps, 4), 64)
        s.shelf.dragActivationDistance = min(max(s.shelf.dragActivationDistance, 20), 300)
        var seen = Set<ActivityKind>()
        s.priority = s.priority.filter { $0.canBeLive && seen.insert($0).inserted }
        for k in ActivityKind.defaultPriority where !seen.contains(k) { s.priority.append(k) }
        s.timers.presetMinutes = Array(Set(s.timers.presetMinutes.filter { $0 > 0 && $0 <= 24 * 60 })).sorted()
        s.systemStats.refreshSeconds = min(max(s.systemStats.refreshSeconds, 0.5), 10)
        var seenWidgets = Set<DashboardWidgetKind>()
        s.dashboard = s.dashboard
            .filter { seenWidgets.insert($0.kind).inserted }
            .map { DashboardItem($0.kind, $0.size) }
        var seenShortcuts = Set<String>()
        s.shortcuts.pinned = s.shortcuts.pinned.filter { !$0.isEmpty && seenShortcuts.insert($0).inserted }
        return s
    }

    // MARK: tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case material, compactStyle, maxActivities, priority, openOnHover, hoverDelayMs, collapseOnMouseLeave
        case glowFromArtwork, displays, showMenuBarIcon, modules
        case openWidthScale, compactMaxWidth, dashboardButton, fullScreen, visibility, revealStyle, whilePlaying, virtualNotchWhenIdle, lockIndicator, hotKey
        case nowPlaying, backgroundApps, calendar, timers, battery, systemStats
        case shelf, downloads, devices, hud, weather, clipboard, shortcuts, privacy, dashboard
    }

    /// Per-module keys from version 0.1, read once and folded into `modules`.
    private enum LegacyKeys: String, CodingKey {
        case nowPlayingModule, timerModule, calendarModule, batteryModule, backgroundAppsModule
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
        openWidthScale = v(.openWidthScale, d.openWidthScale)
        compactMaxWidth = v(.compactMaxWidth, d.compactMaxWidth)
        dashboardButton = v(.dashboardButton, d.dashboardButton)
        fullScreen = v(.fullScreen, d.fullScreen)
        visibility = v(.visibility, d.visibility)
        revealStyle = v(.revealStyle, d.revealStyle)
        whilePlaying = v(.whilePlaying, d.whilePlaying)
        virtualNotchWhenIdle = v(.virtualNotchWhenIdle, d.virtualNotchWhenIdle)
        lockIndicator = v(.lockIndicator, d.lockIndicator)
        hotKey = c.tolerant(.hotKey, d.hotKey)
        modules = c.tolerant(.modules, [String: ModuleSettings]())

        nowPlaying = c.tolerant(.nowPlaying, d.nowPlaying)
        backgroundApps = c.tolerant(.backgroundApps, d.backgroundApps)
        calendar = c.tolerant(.calendar, d.calendar)
        timers = c.tolerant(.timers, d.timers)
        battery = c.tolerant(.battery, d.battery)
        systemStats = c.tolerant(.systemStats, d.systemStats)
        shelf = c.tolerant(.shelf, d.shelf)
        downloads = c.tolerant(.downloads, d.downloads)
        devices = c.tolerant(.devices, d.devices)
        hud = c.tolerant(.hud, d.hud)
        weather = c.tolerant(.weather, d.weather)
        clipboard = c.tolerant(.clipboard, d.clipboard)
        shortcuts = c.tolerant(.shortcuts, d.shortcuts)
        privacy = c.tolerant(.privacy, d.privacy)

        // Unknown widget kinds (from a newer version) are skipped, not fatal.
        if let raw = try? c.decodeIfPresent([[String: String]].self, forKey: .dashboard) {
            dashboard = raw.compactMap { item in
                guard let kind = item["kind"].flatMap(DashboardWidgetKind.init(rawValue:)) else { return nil }
                return DashboardItem(kind, item["size"].flatMap(WidgetSize.init(rawValue:)) ?? .small)
            }
        } else {
            dashboard = d.dashboard
        }

        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self) {
            let pairs: [(LegacyKeys, ActivityKind)] = [(.nowPlayingModule, .nowPlaying), (.timerModule, .timer),
                                                       (.calendarModule, .calendar), (.batteryModule, .battery),
                                                       (.backgroundAppsModule, .backgroundApps)]
            for (key, kind) in pairs where modules[kind.rawValue] == nil {
                if let m = legacy.tolerantOptional(key, kind.defaultModule) { modules[kind.rawValue] = m }
            }
        }
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

extension KeyedDecodingContainer {
    /// Like `tolerant`, but nil when the key is absent.
    func tolerantOptional<T: Codable>(_ key: Key, _ fallback: T) -> T? {
        contains(key) ? tolerant(key, fallback) : nil
    }
}
