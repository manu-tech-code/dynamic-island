import AppKit
import IslandCore
import Observation

/// Now Playing from any app, through the MediaRemote bridge run by /usr/bin/perl.
/// If the bridge can't start, or keeps seeing nothing while Music or Spotify
/// says it's playing, it falls back to asking them with AppleScript.
@Observable
final class NowPlayingService: ActivityProvider {
    enum Source: Equatable { case starting, bridge, appleScript, unavailable }

    let kind = ActivityKind.nowPlaying
    private(set) var info: NowPlayingInfo?
    private(set) var artwork: NSImage?
    private(set) var artworkColor: NSColor?
    private(set) var sourceApp: NSRunningApplication?
    private(set) var source: Source = .starting
    /// When playback last stopped; a paused track leaves the island after the configured delay.
    private(set) var pausedAt: Date?
    private(set) var sessionStart = Date()
    /// Up Next: the player's queue from MediaRemote, or Music's playlist.
    private(set) var queue: MusicQueue?
    private(set) var queueLoading = false
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var queueWanted = 0

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var failures: [Date] = []
    @ObservationIgnored private var artworkCache: (key: String, image: NSImage, color: NSColor?)?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var missedTask: Task<Void, Never>?
    @ObservationIgnored private var playerObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var stopped = false
    /// Bumped when a paused track expires, so observers recompute `activities`.
    private var expiryTick = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var activities: [Activity] {
        _ = expiryTick
        guard let info else { return [] }
        if !info.isPlaying {
            let keep = TimeInterval(settings.settings.nowPlaying.keepPausedMinutes * 60)
            if let pausedAt, Date().timeIntervalSince(pausedAt) >= keep { return [] }
        }
        return [Activity(id: "nowPlaying", kind: .nowPlaying, payload: .nowPlaying(info),
                         relevance: info.isPlaying ? 1 : 0.3, startedAt: sessionStart)]
    }

    #if DEBUG
    /// Swaps in a sample track for offline renders; pass the result back to restore.
    func debugSwapInfo(_ new: NowPlayingInfo?) -> NowPlayingInfo? {
        let old = info
        info = new
        return old
    }
    #endif

    // MARK: lifecycle

    func start() {
        stopped = false
        launchBridge()
        watchPlayers()
    }

    func stop() {
        stopped = true
        fallbackTask?.cancel()
        missedTask?.cancel()
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func launchBridge() {
        // The bridge ships in Resources: the app never links or loads it, only perl does.
        guard let script = Bundle.main.url(forResource: "np", withExtension: "pl"),
              let lib = Bundle.main.url(forResource: "libNowPlayingBridge", withExtension: "dylib") else {
            Log.error("Now Playing bridge files missing from the app bundle")
            startFallback()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["NP_LIB"] = lib.path
        env["NP_MODE"] = "stream:0"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp

        let splitter = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            for line in splitter.feed(chunk) {
                guard let update = NowPlayingParser.parse(line: line) else { continue }
                Task { @MainActor in self?.bridgeReported(update) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { Log.error("np bridge: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.bridgeExited(status: status) }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
            Log.info("Now Playing bridge started (pid \(p.processIdentifier))")
        } catch {
            Log.error("Now Playing bridge failed to launch: \(error)")
            startFallback()
        }
    }

    private func bridgeExited(status: Int32) {
        process = nil
        input = nil
        guard !stopped else { return }
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 60 } + [now]
        Log.error("Now Playing bridge exited with status \(status) (\(failures.count) in the last minute)")
        if failures.count >= 3 {
            startFallback()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(self?.failures.count ?? 1) * 1.5))
                self?.launchBridge()
            }
        }
    }

    /// A line from the bridge. While the fallback runs, only a playing track
    /// brings the bridge back: it seeing nothing is why the fallback runs.
    private func bridgeReported(_ update: NowPlayingUpdate) {
        if source == .appleScript {
            guard update.info?.isPlaying == true else { return }
            fallbackTask?.cancel()
            Log.info("Now Playing back on the system source")
        }
        source = .bridge
        apply(update)
    }

    /// Music and Spotify tell everyone when they play or pause (no permission
    /// needed). One playing while the bridge has nothing playing for a few
    /// seconds means the bridge can't see it, so the fallback takes over.
    private func watchPlayers() {
        guard playerObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            playerObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let playing = note.userInfo?["Player State"] as? String == "Playing"
                MainActor.assumeIsolated { self?.playerReported(playing: playing) }
            })
        }
    }

    private func playerReported(playing: Bool) {
        missedTask?.cancel()
        guard playing, source != .appleScript, !stopped else { return }
        missedTask = Task { [weak self] in
            // The bridge reports a new track within a second when it can see it.
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.source != .appleScript, self.info?.isPlaying != true,
                  AppleScriptPlayer.running() != nil else { return }
            Log.info("Now Playing: a player is playing but the bridge sees nothing")
            self.startFallback()
        }
    }

    private func apply(_ update: NowPlayingUpdate) {
        let wasPlaying = info?.isPlaying ?? false
        let previousTitle = info?.title
        info = update.info
        if update.info?.title != previousTitle || update.info?.isPlaying != wasPlaying {
            if let i = update.info {
                Log.info("now playing: \(i.isPlaying ? "▶" : "⏸") \(private: i.title) — \(private: i.artist) [\(update.event)]")
            } else {
                Log.info("now playing: nothing [\(update.event)]")
            }
        }

        guard let new = update.info else {
            artwork = nil; artworkColor = nil; sourceApp = nil; pausedAt = nil
            return
        }
        if previousTitle == nil { sessionStart = Date() }
        if new.isPlaying {
            pausedAt = nil
            expiryTask?.cancel()
        } else if wasPlaying {
            pausedAt = Date()
            scheduleExpiry()
        } else if pausedAt == nil {
            // First sighting of a paused track: MediaRemote's timestamp says when
            // playback last changed, so a track paused an hour ago doesn't linger.
            pausedAt = min(new.timestamp ?? Date(), Date())
            scheduleExpiry()
        }
        if let pid = new.sourcePID, sourceApp?.processIdentifier != pid {
            sourceApp = NSRunningApplication(processIdentifier: pid)
        }
        updateArtwork(key: new.artworkKey, data: update.artworkData)
        if new.title != previousTitle, queueWanted > 0 { refreshQueue() }
    }

    // MARK: Up Next (Apple Music only)

    var isMusicSource: Bool { sourceApp?.bundleIdentifier == MusicScripting.bundleID }

    /// Views that show Up Next call this on appear and `releaseQueue` on disappear.
    func wantQueue() {
        queueWanted += 1
        refreshQueue()
    }

    func releaseQueue() { queueWanted = max(0, queueWanted - 1) }

    func refreshQueue() {
        queueTask?.cancel()
        queueLoading = queue == nil
        let files = bridgeFiles()
        let music = isMusicSource
        queueTask = Task { [weak self] in
            // The system queue covers Apple Music streaming (and any app that
            // publishes one); Music's AppleScript playlist is the fallback.
            var q = await Self.systemQueue(files: files)
            if (q?.tracks.count ?? 0) <= 1, music { q = await MusicScripting.queue() ?? q }
            guard !Task.isCancelled else { return }
            self?.queueLoading = false
            if let q {
                Log.info("up next: \(private: q.playlist) \(q.currentIndex)/\(q.total), next \(private: q.upNext?.title ?? "none")")
            } else {
                Log.info("up next: unavailable")
            }
            self?.queue = q
        }
    }

    private func bridgeFiles() -> (script: URL, lib: URL)? {
        guard let script = Bundle.main.url(forResource: "np", withExtension: "pl"),
              let lib = Bundle.main.url(forResource: "libNowPlayingBridge", withExtension: "dylib") else { return nil }
        return (script, lib)
    }

    /// Runs the bridge once in queue mode (its own process, so a failure here
    /// can't affect the Now Playing stream).
    nonisolated private static func systemQueue(files: (script: URL, lib: URL)?, count: Int = 40) async -> MusicQueue? {
        guard let files else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [files.script.path]
            var env = ProcessInfo.processInfo.environment
            env["NP_LIB"] = files.lib.path
            env["NP_MODE"] = "queue:\(count)"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let d = out.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: proc.terminationStatus == 0 ? d : nil)
            }
            do { try p.run() } catch { continuation.resume(returning: nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        }
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]], !items.isEmpty else { return nil }
        let location = (obj["location"] as? NSNumber)?.intValue ?? 0
        let tracks = items.enumerated().map { i, item in
            QueueTrack(index: i + 1, title: item["title"] as? String ?? "Unknown",
                       artist: item["artist"] as? String ?? "",
                       duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0)
        }
        return MusicQueue(playlist: "Up Next", currentIndex: location + 1, total: tracks.count, tracks: tracks)
    }

    func playQueueTrack(_ track: QueueTrack) {
        guard queue?.playable == true else { return }
        Task {
            await MusicScripting.play(index: track.index)
            try? await Task.sleep(for: .milliseconds(400))
            refreshQueue()
        }
    }

    private func updateArtwork(key: String?, data: Data?) {
        guard let key else { artwork = nil; artworkColor = nil; return }
        if let cache = artworkCache, cache.key == key {
            if artwork !== cache.image { artwork = cache.image; artworkColor = cache.color }
            return
        }
        // Decoded at the most it's shown at (the open player), not the size it came in.
        guard let data, let image = Thumbnail.image(data: data, maxPixels: 512) ?? NSImage(data: data) else { return }
        let color = ArtworkColor.dominant(in: image)
        artworkCache = (key, image, color)
        artwork = image
        artworkColor = color
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let keep = TimeInterval(settings.settings.nowPlaying.keepPausedMinutes * 60)
        let remaining = max(0, keep - Date().timeIntervalSince(pausedAt ?? Date()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining + 0.5))
            guard !Task.isCancelled else { return }
            self?.expiryTick += 1
        }
    }

    // MARK: commands

    func togglePlayPause() {
        if var i = info {
            // Optimistic update; the bridge confirms a moment later.
            i.elapsedAtTimestamp = i.elapsed(at: Date())
            i.timestamp = Date()
            i.isPlaying.toggle()
            info = i
            if !i.isPlaying { pausedAt = Date(); scheduleExpiry() } else { pausedAt = nil }
        }
        send("toggle", script: "playpause")
    }

    func next() { send("next", script: "next track") }
    func previous() { send("previous", script: "previous track") }

    func seek(to seconds: TimeInterval) {
        if var i = info { i.elapsedAtTimestamp = seconds; i.timestamp = Date(); info = i }
        send("seek \(seconds)", script: nil)
    }

    func openSourceApp() {
        guard let url = sourceApp?.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String, script: String?) {
        if source == .bridge, let input {
            try? input.write(contentsOf: Data((command + "\n").utf8))
        } else if let script, let player = AppleScriptPlayer.running() {
            Task { [weak self] in
                await player.run(script)
                await self?.pollFallback()
            }
        }
    }

    // MARK: AppleScript fallback

    private func startFallback() {
        guard source != .appleScript else { return }
        source = .appleScript
        missedTask?.cancel()
        Log.info("Now Playing using the AppleScript fallback (Music and Spotify only)")
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollFallback()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Asks the running player (off the main thread, through osascript).
    private func pollFallback() async {
        guard source == .appleScript else { return }
        let state = await AppleScriptPlayer.running()?.state()
        // The bridge may have come back while the script ran.
        guard source == .appleScript, state != nil || info != nil else { return }
        apply(NowPlayingUpdate(info: state, artworkData: nil, event: "fallback"))
    }
}

/// Splits a byte stream into newline-terminated lines. Only touched from the
/// pipe's serial readability handler.
nonisolated final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}

/// Music or Spotify, whichever is running, via AppleScript. Never launches a
/// player. Scripts run in osascript, off the main thread, like `MusicScripting`.
struct AppleScriptPlayer {
    let bundleID: String

    static func running() -> AppleScriptPlayer? {
        for id in ["com.apple.Music", "com.spotify.client"]
        where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            return AppleScriptPlayer(bundleID: id)
        }
        return nil
    }

    func run(_ command: String) async {
        _ = await MusicScripting.run("tell application id \"\(bundleID)\" to \(command)")
    }

    func state() async -> NowPlayingInfo? {
        let src = """
        tell application id "\(bundleID)"
            set s to player state as text
            if s is "stopped" then return ""
            set t to current track
            return s & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (album of t) & "\t" & ((duration of t) as text) & "\t" & ((player position) as text)
        end tell
        """
        // Every two seconds: a player in an odd state shouldn't fill the log.
        guard let out = await MusicScripting.run(src, logsErrors: false), !out.isEmpty else { return nil }
        let f = out.components(separatedBy: "\t")
        guard f.count >= 6 else { return nil }
        var duration = Double(f[4].replacingOccurrences(of: ",", with: "."))
        if bundleID == "com.spotify.client", let d = duration { duration = d / 1000 } // Spotify reports ms
        let playing = f[0] == "playing"
        return NowPlayingInfo(title: f[1], artist: f[2], album: f[3], duration: duration,
                              elapsedAtTimestamp: Double(f[5].replacingOccurrences(of: ",", with: ".")), timestamp: Date(),
                              playbackRate: playing ? 1 : 0, isPlaying: playing,
                              sourcePID: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier)
    }
}

enum ArtworkColor {
    /// Average colour of the artwork, lifted so it reads as a glow.
    static func dominant(in image: NSImage) -> NSColor? {
        let size = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for x in 0..<size { for y in 0..<size {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            // Weight saturated pixels more, so a grey border doesn't wash the colour out.
            let w = 0.25 + c.saturationComponent
            r += c.redComponent * w; g += c.greenComponent * w; b += c.blueComponent * w; weight += w
        } }
        guard weight > 0 else { return nil }
        let avg = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
        return NSColor(hue: avg.hueComponent, saturation: min(1, avg.saturationComponent * 1.25 + 0.1),
                       brightness: max(0.65, avg.brightnessComponent), alpha: 1)
    }
}
