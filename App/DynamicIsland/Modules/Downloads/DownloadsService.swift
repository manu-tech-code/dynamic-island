import AppKit
import IslandCore
import Observation

/// Downloads in progress, from the file progress browsers publish for
/// ~/Downloads (the same feed Finder uses for its progress bars).
@Observable
final class DownloadsService: ActivityProvider {
    let kind = ActivityKind.downloads
    private(set) var downloads: [DownloadInfo] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var tracked: [String: Tracked] = [:]

    private final class Tracked {
        let progress: Progress
        var observations: [NSKeyValueObservation] = []
        let fileURL: URL?
        init(progress: Progress, fileURL: URL?) { self.progress = progress; self.fileURL = fileURL }
    }

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
    }

    var activities: [Activity] {
        downloads.map { d in
            Activity(id: "download-\(d.id)", kind: .downloads, payload: .download(d),
                     relevance: d.fraction.map { 0.5 + $0 / 2 } ?? 0.5, startedAt: d.startedAt)
        }
    }

    func start() {
        guard subscriber == nil,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        // Apple: "The system invokes the blocks you provide on the main thread."
        subscriber = Progress.addSubscriber(forFileURL: dir) { [weak self] progress in
            let box = SendableBox(progress)
            let id = UUID().uuidString
            MainActor.assumeIsolated { self?.track(box.value, id: id) }
            return {
                MainActor.assumeIsolated { self?.finish(id) }
            }
        }
        Log.info("downloads: watching \(dir.path)")
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
    }

    func reveal(_ download: DownloadInfo) {
        guard let url = tracked[download.id]?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finalURL(for: url)])
    }

    // MARK: tracking

    private func track(_ progress: Progress, id: String) {
        let url = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
        let t = Tracked(progress: progress, fileURL: url)
        tracked[id] = t
        let update: @Sendable (Progress) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh(id) }
        }
        t.observations = [
            progress.observe(\.fractionCompleted, options: [.new], changeHandler: { p, _ in update(p) }),
            progress.observe(\.completedUnitCount, options: [.new], changeHandler: { p, _ in update(p) }),
        ]
        let name = url.map { DownloadNames.clean($0.lastPathComponent) } ?? (progress.localizedDescription ?? "Download")
        downloads.append(DownloadInfo(id: id, name: name))
        refresh(id)
        Log.info("download started: \(name)")
    }

    private func refresh(_ id: String) {
        guard let t = tracked[id], let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        let p = t.progress
        var d = downloads[i]
        d.fraction = p.isIndeterminate || p.totalUnitCount <= 0 ? nil : min(1, max(0, p.fractionCompleted))
        if p.kind == .file || p.fileTotalCount != nil {
            d.completedBytes = p.completedUnitCount > 0 ? p.completedUnitCount : nil
            d.totalBytes = p.totalUnitCount > 0 ? p.totalUnitCount : nil
        }
        if d != downloads[i] { downloads[i] = d }
    }

    private func finish(_ id: String) {
        guard let t = tracked.removeValue(forKey: id) else { return }
        t.observations.forEach { $0.invalidate() }
        let info = downloads.first { $0.id == id }
        downloads.removeAll { $0.id == id }
        let done = t.progress.fractionCompleted >= 0.99 && !t.progress.isCancelled
        Log.info("download ended: \(info?.name ?? "?") \(done ? "complete" : "stopped")")
        guard done, settings.settings.downloads.alertWhenDone, let info, let url = t.fileURL else { return }
        engine.post(IslandAlert(kind: .downloads, style: .downloadFinished(name: info.name, path: finalURL(for: url).path), holdSeconds: 5))
    }

    /// Browsers publish progress on the partial file; the finished file drops the suffix.
    private func finalURL(for url: URL) -> URL {
        let cleaned = DownloadNames.clean(url.lastPathComponent)
        let final = url.deletingLastPathComponent().appendingPathComponent(cleaned)
        return FileManager.default.fileExists(atPath: final.path) ? final : url
    }
}
