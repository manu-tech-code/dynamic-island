import Foundation

public enum IslandFormat {
    /// "4:59", "12:03", "1:02:03". Rounds up so a timer never shows 0:00 while running.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Track position: "1:24", rounds down.
    public static func position(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Short relative time for the compact island: "Now", "5m", "1h 5m".
    public static func untilShort(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Token counts, short: "950", "12.5K", "489.3M", "1.2B".
    public static func tokens(_ n: Int) -> String {
        switch Double(n) {
        case 1e9...: String(format: "%.1fB", Double(n) / 1e9)
        case 1e6...: String(format: "%.1fM", Double(n) / 1e6)
        case 1e3...: String(format: "%.1fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    /// Dollars, short: "$0.42", "$12.40", "$123", "$1.2K".
    public static func dollars(_ v: Double) -> String {
        switch max(0, v) {
        case 1000...: String(format: "$%.1fK", v / 1000)
        case 100...: String(format: "$%.0f", v)
        default: String(format: "$%.2f", max(0, v))
        }
    }

    /// A clock that counts up, for an agent at work: "0:42", "4:12", then "1h 05".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh %02d", s / 3600, (s % 3600) / 60)
    }

    /// How long something took: "40 s", "6 m 40 s", "1 h 5 m".
    public static func took(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) m" : "\(s / 60) m \(s % 60) s" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) m"
    }

    /// How long ago, for a list of messages: "now", "4m", "2h", "3d".
    public static func ago(_ date: Date, from now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    /// "in 18 min", "now", "in 1 h 5 min".
    public static func untilLong(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    /// "3 h 40 m", "25 m".
    public static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }
}
