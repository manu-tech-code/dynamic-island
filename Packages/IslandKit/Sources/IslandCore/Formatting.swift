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
