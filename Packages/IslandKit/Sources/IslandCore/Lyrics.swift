import Foundation

public struct LyricLine: Equatable, Sendable, Identifiable {
    public var id: Int
    public var time: TimeInterval
    public var text: String

    public init(id: Int, time: TimeInterval, text: String) {
        self.id = id; self.time = time; self.text = text
    }
}

public struct Lyrics: Equatable, Sendable {
    /// Time-stamped lines, sorted. Empty when only plain lyrics exist.
    public var synced: [LyricLine]
    public var plain: String?
    public var instrumental: Bool

    public init(synced: [LyricLine], plain: String?, instrumental: Bool = false) {
        self.synced = synced; self.plain = plain; self.instrumental = instrumental
    }

    /// The line being sung at `time`: the last line that has started.
    public func currentIndex(at time: TimeInterval) -> Int? {
        guard let first = synced.first, time >= first.time else { return nil }
        var lo = 0, hi = synced.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if synced[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Parses LRC lyrics: `[mm:ss.xx] line`, several stamps per line allowed,
/// `[offset:±ms]` honoured, other `[tag:value]` lines ignored.
public enum LyricsParser {
    public static func parseLRC(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var entries: [(TimeInterval, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let lyric = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { entries.append((t, lyric)) }
        }
        // A positive LRC offset means the lyrics should appear earlier.
        return entries
            .map { (max(0, $0.0 - offset), $0.1) }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Double(parts[0]), minutes >= 0 else { return nil }
        let secPart = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secPart), seconds >= 0, seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }
}
