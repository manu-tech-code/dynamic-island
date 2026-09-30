import Foundation

/// One line of output from the Now Playing bridge.
public struct NowPlayingUpdate: Equatable, Sendable {
    /// nil when nothing is loaded in any player.
    public var info: NowPlayingInfo?
    /// Only present when the artwork changed since the previous line.
    public var artworkData: Data?
    public var event: String

    public init(info: NowPlayingInfo?, artworkData: Data?, event: String) {
        self.info = info; self.artworkData = artworkData; self.event = event
    }
}

/// Parses the JSON lines printed by NowPlayingBridge (`np_run` in stream mode):
/// `{"event":"…","at":…,"state":{"ok":…,"isPlaying":…,"pid":…,"info":{…}},"artwork":"<base64>"}`
public enum NowPlayingParser {
    public static func parse(line: Data) -> NowPlayingUpdate? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let event = obj["event"] as? String ?? "?"
        let state = obj["state"] as? [String: Any] ?? obj
        let artwork = (obj["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        guard let info = state["info"] as? [String: Any], !info.isEmpty else {
            return NowPlayingUpdate(info: nil, artworkData: nil, event: event)
        }
        let title = (info["Title"] as? String) ?? ""
        guard !title.isEmpty else { return NowPlayingUpdate(info: nil, artworkData: nil, event: event) }
        let rate = number(info["PlaybackRate"]) ?? 0
        let playingFlag = (state["isPlaying"] as? Bool) ?? (number(state["isPlaying"]).map { $0 != 0 })
        let pid = number(state["pid"]).map { Int32($0) }
        let parsed = NowPlayingInfo(
            title: title,
            artist: (info["Artist"] as? String) ?? "",
            album: (info["Album"] as? String) ?? "",
            duration: number(info["Duration"]).flatMap { $0 > 0 ? $0 : nil },
            elapsedAtTimestamp: number(info["ElapsedTime"]),
            timestamp: number(info["Timestamp"]).map { Date(timeIntervalSince1970: $0) },
            playbackRate: rate,
            isPlaying: playingFlag ?? (rate > 0),
            artworkKey: obj["artworkKey"] as? String ?? (info["ArtworkIdentifier"] as? String),
            sourcePID: (pid ?? 0) > 0 ? pid : nil
        )
        return NowPlayingUpdate(info: parsed, artworkData: artwork, event: event)
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let d as Double: d
        case let i as Int: Double(i)
        default: nil
        }
    }
}
