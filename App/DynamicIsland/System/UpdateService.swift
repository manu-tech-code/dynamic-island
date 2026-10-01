import AppKit
import IslandCore
import Observation
import Sparkle

/// Updates through Sparkle. Once a day it reads the appcast attached to the
/// latest GitHub release, checks the download's EdDSA signature against the
/// key in Info.plist, and replaces the app on relaunch. Sparkle's window is
/// replaced by ours (`UpdateDriver`): a timeline of releases with Update Now.
/// An update found in the background shows on the island first.
@Observable
final class UpdateService: NSObject {
    /// A version found by a scheduled check, waiting for you.
    private(set) var available: String?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let driver = UpdateDriver()
    @ObservationIgnored private var updater: SPUUpdater?

    init(engine: ActivityEngine) {
        self.engine = engine
        super.init()
    }

    func start() {
        guard updater == nil else { return }
        driver.onBackgroundUpdate = { [weak self] version in
            self?.available = version
            Log.info("update available: \(version)")
            self?.engine.post(IslandAlert(kind: .battery, style: .updateAvailable(version: version), holdSeconds: 8))
        }
        driver.onSessionEnd = { [weak self] in self?.available = nil }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            Log.error("updates: couldn't start (\(error.localizedDescription))")
        }
        self.updater = updater
        Log.info("updates: \(automaticallyChecks ? "checking daily" : "automatic checks off"), last \(lastChecked.map { "\($0)" } ?? "never")")
    }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    /// The update window: the waiting update, or a fresh check.
    func checkForUpdates() {
        if driver.hasPendingUpdate {
            driver.showPendingUpdate()
            return
        }
        #if DEBUG
        guard Self.debugFeed != nil else {
            engine.post(IslandAlert(kind: .battery, style: .message(
                title: "No updates in development builds", subtitle: "Set DebugFeedURL to try a local appcast", symbol: "hammer.fill")))
            return
        }
        #endif
        updater?.checkForUpdates()
    }

    #if DEBUG
    /// Development builds share the release's bundle id and defaults, so they
    /// never check the real feed: only a local one, set with
    /// `defaults write com.dynamicisland.mac DebugFeedURL file:///…/appcast.xml`.
    static var debugFeed: String? { UserDefaults.standard.string(forKey: "DebugFeedURL") }

    func debugBackgroundCheck() { updater?.checkForUpdatesInBackground() }

    /// The update window in a given step, with real notes and nothing to install.
    func debugWindow(_ phase: UpdateFlow.Phase, version: String) { driver.debugShow(phase, version: version) }
    var debugFlow: UpdateFlow { driver.flow }
    func debugPress(_ button: String) { driver.debugPress(button) }
    #endif
}

extension UpdateService: SPUUpdaterDelegate {
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
