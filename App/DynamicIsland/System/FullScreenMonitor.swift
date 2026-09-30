import AppKit
import CoreGraphics
import Observation

/// Which displays have a full-screen app in front. macOS has no public
/// "is this Space full screen" call, so this checks whether the frontmost app
/// has a normal window exactly covering the display. Window bounds and owner
/// don't need Screen Recording permission (window titles would).
@Observable
final class FullScreenMonitor {
    private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: Task<Void, Never>?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        evaluate()
    }

    func isFullScreen(_ display: CGDirectDisplayID) -> Bool { fullScreenDisplays.contains(display) }

    /// Checks now and again after the Space-switch animation settles.
    private func schedule() {
        evaluate()
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func evaluate() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ProcessInfo.processInfo.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            if !fullScreenDisplays.isEmpty { fullScreenDisplays = [] }
            return
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var found = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            // CG window bounds use a top-left origin on the main display.
            let f = screen.frame
            let cgFrame = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
            let covered = info.contains { w in
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == front,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
                return abs(rect.minX - cgFrame.minX) < 1 && abs(rect.minY - cgFrame.minY) < 1
                    && abs(rect.width - cgFrame.width) < 1 && abs(rect.height - cgFrame.height) < 1
            }
            if covered { found.insert(IslandManager.displayID(screen)) }
        }
        if found != fullScreenDisplays {
            fullScreenDisplays = found
            Log.info("full screen on displays: \(found.sorted())")
        }
    }
}
