import Foundation

/// Finds a video-call link in a calendar event so the island can offer "Join".
public enum MeetingLinks {
    static let hostSuffixes = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "facetime.apple.com", "chime.aws", "gotomeeting.com",
    ]

    /// Checks the event URL first, then location, then notes; returns the first call link.
    public static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            if let found = firstMeetingURL(in: text) { return found }
        }
        return nil
    }

    public static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return hostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func firstMeetingURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, isMeeting(url) { return url }
        }
        return nil
    }
}
