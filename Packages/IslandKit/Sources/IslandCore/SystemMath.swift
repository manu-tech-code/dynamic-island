import Foundation

/// Media keys arrive as NX_SYSDEFINED events (subtype 8). `data1` packs the
/// key code and state: code in bits 16–31, flags in 8–15 (0xA = down, 0xB = up),
/// repeat in bit 0.
public enum MediaKey: Int, Sendable {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7

    public struct Press: Equatable, Sendable {
        public let key: MediaKey
        public let isDown: Bool
        public let isRepeat: Bool
    }

    public static func decode(data1: Int) -> Press? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = (data1 & 0x0000_FF00) >> 8
        guard let key = MediaKey(rawValue: code), flags == 0xA || flags == 0xB else { return nil }
        return Press(key: key, isDown: flags == 0xA, isRepeat: (data1 & 0x1) == 1)
    }
}

public enum VolumeMath {
    /// One key press: `steps` steps across the range, or four times finer
    /// with ⌥⇧ like macOS. Snaps to the step grid so values don't drift.
    public static func step(_ value: Double, up: Bool, steps: Int, fine: Bool) -> Double {
        let n = Double(max(1, steps) * (fine ? 4 : 1))
        let current = (value * n).rounded()
        let next = current + (up ? 1 : -1)
        return min(1, max(0, next / n))
    }
}

/// Bytes received and sent by one network interface, from its 64-bit counters.
public struct InterfaceBytes: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received; self.sent = sent
    }
}

public enum NetworkMath {
    /// Bytes moved between two readings, interface by interface, then added up.
    /// An interface only in one reading (it came or went) counts nothing, and so
    /// does one whose counters went back (it was reset), so neither shows as a
    /// spike. Summing first and subtracting the totals would turn either into one.
    public static func moved(from old: [String: InterfaceBytes], to new: [String: InterfaceBytes]) -> InterfaceBytes {
        var total = InterfaceBytes(received: 0, sent: 0)
        for (name, now) in new {
            guard let before = old[name] else { continue }
            if now.received >= before.received { total.received &+= now.received - before.received }
            if now.sent >= before.sent { total.sent &+= now.sent - before.sent }
        }
        return total
    }
}

public enum DownloadNames {
    /// "Report.pdf.download" → "Report.pdf" (Safari, Chrome, Firefox partial files).
    public static func clean(_ name: String) -> String {
        for suffix in [".download", ".crdownload", ".part", ".partial"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

public struct ClipboardEntry: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case link(URL)
        case files([String])
        case image(width: Int, height: Int)
    }

    public var id: UUID
    public var content: Content
    public var sourceApp: String?
    public var copiedAt: Date
    /// Opaque key for spotting duplicates (the text, or an image hash).
    public var fingerprint: String

    public init(id: UUID = UUID(), content: Content, sourceApp: String?, copiedAt: Date = Date(), fingerprint: String) {
        self.id = id; self.content = content; self.sourceApp = sourceApp; self.copiedAt = copiedAt; self.fingerprint = fingerprint
    }

    public var preview: String {
        switch content {
        case .text(let t): t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .link(let u): u.absoluteString
        case .files(let paths): paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        case .image(let w, let h): "Image \(w) × \(h)"
        }
    }
}

public enum ClipboardHistory {
    /// Newest first; copying something already in the list moves it to the top.
    public static func inserting(_ entry: ClipboardEntry, into list: [ClipboardEntry], max: Int) -> [ClipboardEntry] {
        var out = list.filter { $0.fingerprint != entry.fingerprint }
        out.insert(entry, at: 0)
        return Array(out.prefix(Swift.max(1, max)))
    }
}
