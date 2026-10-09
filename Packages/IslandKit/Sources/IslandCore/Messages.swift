import Foundation

/// A message from another app, read from the notification banner macOS showed
/// for it: which app, who it's from, where (a channel, a group, a subject) and
/// what it says.
public struct MessageInfo: Equatable, Sendable, Identifiable {
    /// Notification Center's id for the banner.
    public var id: String
    public var app: String
    public var bundleID: String?
    public var sender: String
    public var context: String
    public var text: String
    public var date: Date

    public init(id: String, app: String, bundleID: String? = nil, sender: String, context: String = "", text: String, date: Date = .now) {
        self.id = id; self.app = app; self.bundleID = bundleID
        self.sender = sender; self.context = context; self.text = text; self.date = date
    }

    /// Up to two initials for the sender's circle: "Ama Mensah" → "AM", "#design" → "D".
    public var initials: String {
        let words = sender.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .map { $0.drop(while: { !$0.isLetter && !$0.isNumber }) }
            .filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? String(app.prefix(1)).uppercased() : letters.joined()
    }

    /// The banner's accessibility description reads "<App>, <title>, <subtitle>,
    /// <body>": the app is what comes before the title.
    public static func appName(fromBannerDescription description: String, title: String) -> String {
        if !title.isEmpty, let r = description.range(of: ", " + title) { return String(description[..<r.lowerBound]) }
        return description.components(separatedBy: ", ").first ?? description
    }
}

/// How a message shows on the island (Settings › Messages).
public enum MessageAlertStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The island opens into a card: the app, the sender, two lines, Open.
    case card
    /// The app's icon and the sender in the ears; the message drops down on hover.
    case ears
    /// One line: the sender, and the message scrolling past.
    case ticker
    /// Messages that arrive together pile up, newest on top; hover lists them.
    case stack
    /// Like ears, then the app's icon stays with an unread count until it's opened.
    case badges

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .card: "Card"
        case .ears: "Ears, message on hover"
        case .ticker: "Ticker"
        case .stack: "Stack"
        case .badges: "Ears, then a badge"
        }
    }

    /// Shown in the ears like a compact activity, rather than as a card.
    public var isCompact: Bool { self == .ears || self == .ticker || self == .badges }
}

/// Unread messages kept on the island after their alert (the badges style).
public struct UnreadApp: Equatable, Sendable, Identifiable {
    public var id: String { app }
    public var app: String
    public var bundleID: String?
    public var count: Int
    public var lastSender: String

    public init(app: String, bundleID: String? = nil, count: Int, lastSender: String) {
        self.app = app; self.bundleID = bundleID; self.count = count; self.lastSender = lastSender
    }
}

public struct MessageAlertSettings: Codable, Equatable, Sendable {
    public var style: MessageAlertStyle = .card
    /// "New message" instead of what it says, for screen sharing or a café.
    public var hideText = false
    /// Which apps show on the island, by app name, as chosen in Settings. An app
    /// that isn't here yet goes by `shownByDefault`.
    public var apps: [String: Bool] = [:]
    /// How long a message stays (the ticker stays until it has scrolled by).
    public var holdSeconds: Double = 5
    /// Keep macOS's own banner out of sight for apps the island shows, so a
    /// message appears once. It still goes into Notification Center's list.
    public var hideSystemBanner = true
    /// Keep the messages that reached the island in a list on it (the dashboard's
    /// messages button and widget), until the app quits.
    public var keepRecent = true
    /// How many recent messages the list keeps.
    public var recentLimit = 20
    public static let recentLimitRange = 5...100
    public init() {}

    /// Whether this app's notifications show on the island.
    public func shows(app: String) -> Bool { apps[app] ?? Self.shownByDefault(app: app) }

    /// Every app shows until it's turned off, except music and podcast apps:
    /// they announce each song, which the island shows already.
    public static func shownByDefault(app: String) -> Bool { !MessagingApps.isMedia(app: app) }
}

/// Messages that reached the island lately, newest first, so one you missed is
/// still there to open. Kept only in memory, never saved: they go when the app quits.
public struct RecentMessages: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var message: MessageInfo
        /// Opened from the island, or its app was opened since.
        public var read: Bool
        public var id: String { message.id }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var limit: Int

    public init(limit: Int = MessageAlertSettings().recentLimit) { self.limit = max(1, limit) }

    public var isEmpty: Bool { entries.isEmpty }
    public var unreadCount: Int { entries.count { !$0.read } }

    /// On top, unread. The same notification read again replaces itself, and the
    /// oldest go once there are more than the limit.
    public mutating func add(_ message: MessageInfo) {
        entries.removeAll { $0.id == message.id }
        entries.insert(Entry(message: message, read: false), at: 0)
        trim()
    }

    public mutating func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        trim()
    }

    public mutating func markRead(id: String) {
        for i in entries.indices where entries[i].id == id { entries[i].read = true }
    }

    /// Opening an app reads its messages.
    public mutating func markRead(app: String?, bundleID: String?) {
        for i in entries.indices {
            let m = entries[i].message
            if (bundleID != nil && m.bundleID == bundleID) || (app != nil && m.app == app) { entries[i].read = true }
        }
    }

    public mutating func markAllRead() {
        for i in entries.indices { entries[i].read = true }
    }

    public mutating func remove(id: String) { entries.removeAll { $0.id == id } }
    public mutating func removeAll() { entries = [] }

    private mutating func trim() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}

/// Apps people send messages with, for "only messaging apps".
public enum MessagingApps {
    public static let bundleIDs: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.MobileSMS",
        "com.microsoft.teams2", "com.microsoft.teams", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord",
        "org.whispersystems.signal-desktop", "com.microsoft.Outlook", "us.zoom.xos", "com.facebook.archon", "com.readdle.SparkDesktop",
        "com.skype.skype", "im.riot.app", "com.beeper.beeper-desktop", "com.viber.osx", "jp.naver.line.mac", "com.tencent.xinWeChat",
        "com.superhuman.electron", "com.mimestream.Mimestream", "com.cisco.webexmeetingsapp", "com.google.Chrome.app.gmail",
    ]

    public static let names: Set<String> = [
        "whatsapp", "slack", "mail", "messages", "microsoft teams", "teams", "telegram", "discord", "signal", "microsoft outlook",
        "outlook", "zoom", "zoom.us", "messenger", "spark", "skype", "element", "beeper", "viber", "line", "wechat", "superhuman",
        "mimestream", "airmail", "thunderbird", "webex", "gmail", "google chat", "facetime",
    ]

    /// Apps whose notifications are only "now playing": the island shows the song already.
    public static let mediaApps: Set<String> = [
        "music", "spotify", "podcasts", "tv", "tidal", "deezer", "amazon music", "youtube music", "audible", "vox", "doppler",
    ]

    public static func isMedia(app: String) -> Bool { mediaApps.contains(app.lowercased()) }

    /// Music and podcast apps, so Settings can list them (off) before they've said anything.
    public static let mediaBundleIDs: Set<String> = ["com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV"]

    public static func isMessaging(app: String, bundleID: String?) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID) { return true }
        return names.contains(app.lowercased())
    }
}
