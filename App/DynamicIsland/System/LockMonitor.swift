import AppKit
import Observation

/// Whether the Mac is locked (the lock screen is up, not just the display
/// asleep), from the system's lock and unlock notifications.
@Observable
final class LockMonitor {
    private(set) var isLocked = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        isLocked = Self.sessionIsLocked
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(locked) }
            })
        }
    }

    private func set(_ locked: Bool) {
        guard locked != isLocked else { return }
        Log.info(locked ? "screen locked" : "screen unlocked")
        isLocked = locked
    }

    /// At launch, the session dictionary knows whether the screen is locked.
    private static var sessionIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    #if DEBUG
    /// Plays a lock and then an unlock, without locking the Mac.
    func debugSimulate(seconds: Double = 3) {
        set(true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.set(false)
        }
    }
    #endif
}
