import AppKit
import IslandCore
import Observation
import Sparkle

/// Updates through Sparkle. Once a day it reads the appcast attached to the
/// latest GitHub release, checks the download's EdDSA signature against the
/// key in Info.plist, and replaces the app on relaunch. As a menu bar app it
/// uses Sparkle's gentle reminders: an update found in the background shows on
/// the island instead of a window popping up over your work.
@Observable
final class UpdateService: NSObject {
    /// A version found by a scheduled check, waiting for you.
    private(set) var available: String?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    init(engine: ActivityEngine) {
        self.engine = engine
        super.init()
    }

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        Log.info("updates: \(automaticallyChecks ? "checking daily" : "automatic checks off"), last \(lastChecked.map { "\($0)" } ?? "never")")
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    /// Sparkle's window: the update with its notes and Install, or "you're up to date".
    func checkForUpdates() {
        #if DEBUG
        guard Self.debugFeed != nil else {
            engine.post(IslandAlert(kind: .battery, style: .message(
                title: "No updates in development builds", subtitle: "Set DebugFeedURL to try a local appcast", symbol: "hammer.fill")))
            return
        }
        #endif
        available = nil
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    #if DEBUG
    /// Development builds share the release's bundle id and defaults, so they
    /// never check the real feed: only a local one, set with
    /// `defaults write com.dynamicisland.mac DebugFeedURL file:///…/appcast.xml`.
    static var debugFeed: String? { UserDefaults.standard.string(forKey: "DebugFeedURL") }

    func debugBackgroundCheck() { controller?.updater.checkForUpdatesInBackground() }
    #endif
}

extension UpdateService: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("updates: found \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info("updates: up to date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        Log.error("updates: \(error.localizedDescription)\(underlying.map { " (\($0.domain) \($0.code): \($0.localizedDescription))" } ?? "")")
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? { Self.debugFeed }
    func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool { Self.debugFeed != nil }
    #endif
}

extension UpdateService: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows its window right away only when the app is in front
    /// (just opened, say); otherwise the island tells you.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        available = update.displayVersionString
        Log.info("update available: \(update.displayVersionString)")
        engine.post(IslandAlert(kind: .battery, style: .updateAvailable(version: update.displayVersionString), holdSeconds: 8))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}
