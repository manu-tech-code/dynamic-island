import Foundation

struct QueueTrack: Identifiable, Equatable {
    let index: Int
    let title: String
    let artist: String
    let duration: TimeInterval
    var id: Int { index }
}

struct MusicQueue: Equatable {
    let playlist: String
    let currentIndex: Int
    let total: Int
    let tracks: [QueueTrack]
    /// True when rows can be clicked to play (Music library playlists).
    var playable = false

    var upNext: QueueTrack? { tracks.first { $0.index == currentIndex + 1 } }
}

struct MusicAirPlayDevice: Identifiable, Equatable {
    let name: String
    let kind: String
    let selected: Bool
    var id: String { name }

    var symbolName: String {
        switch kind.lowercased() {
        case let k where k.contains("computer"): "laptopcomputer"
        case let k where k.contains("tv"): "appletv"
        case let k where k.contains("homepod"): "homepod"
        case let k where k.contains("bluetooth"): "headphones"
        default: "hifispeaker.fill"
        }
    }
}

/// Apple Music features MediaRemote doesn't expose: the playlist around the
/// current track, playing a track from it, and Music's AirPlay speakers.
/// Runs `osascript` off the main thread; macOS asks once for Automation access.
enum MusicScripting {
    static let bundleID = "com.apple.Music"

    static func queue(before: Int = 3, after: Int = 40) async -> MusicQueue? {
        let script = """
        tell application id "\(bundleID)"
            if player state is stopped then return "STOPPED"
            set p to current playlist
            set cid to persistent ID of current track
            set i to 0
            try
                set i to index of current track
                if persistent ID of track i of p is not cid then set i to 0
            end try
            if i is 0 then set i to index of (first track of p whose persistent ID is cid)
            set n to count of tracks of p
            set a to i - \(before)
            if a < 1 then set a to 1
            set b to i + \(after)
            if b > n then set b to n
            set out to (name of p) & tab & i & tab & n & linefeed
            repeat with k from a to b
                set t to track k of p
                set out to out & k & tab & (name of t) & tab & (artist of t) & tab & (duration of t) & linefeed
            end repeat
            return out
        end tell
        """
        guard let out = await run(script), out != "STOPPED" else { return nil }
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        let head = lines.removeFirst().components(separatedBy: "\t")
        guard head.count >= 3, let current = Int(head[1]), let total = Int(head[2]) else { return nil }
        let tracks: [QueueTrack] = lines.compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, let i = Int(f[0]) else { return nil }
            return QueueTrack(index: i, title: f[1], artist: f[2], duration: number(f[3]) ?? 0)
        }
        return MusicQueue(playlist: head[0], currentIndex: current, total: total, tracks: tracks, playable: true)
    }

    static func play(index: Int) async {
        _ = await run("tell application id \"\(bundleID)\" to play track \(index) of current playlist")
    }

    static func airPlayDevices() async -> [MusicAirPlayDevice] {
        let script = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with d in (every AirPlay device whose available is true)
                set out to out & (name of d) & tab & (kind of d as text) & tab & (selected of d) & linefeed
            end repeat
            return out
        end tell
        """
        guard let out = await run(script) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3 else { return nil }
            return MusicAirPlayDevice(name: f[0], kind: f[1], selected: f[2] == "true")
        }
    }

    /// Adds or removes a speaker from Music's AirPlay group (multi-room).
    static func setAirPlay(_ name: String, selected: Bool) async {
        _ = await run("tell application id \"\(bundleID)\" to set selected of AirPlay device \"\(escape(name))\" to \(selected)")
    }

    // MARK: running

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Returns stdout, or nil if the script failed or took longer than `timeout`.
    nonisolated static func run(_ source: String, timeout: TimeInterval = 5, logsErrors: Bool = true) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    // Its message can quote a track or a speaker by name.
                    if logsErrors { Log.error("osascript failed (\(proc.terminationStatus)): \(private: errText.trimmingCharacters(in: .whitespacesAndNewlines))") }
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines))
                }
            }
            do {
                try p.run()
            } catch {
                Log.error("osascript launch failed: \(error)")
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}
