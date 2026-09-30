import AppKit
import Observation

/// Appearance settings the island reads for the parts it draws itself. The
/// glass body needs none of this: system Liquid Glass follows the slider,
/// Reduce Transparency and Increase Contrast by itself.
@Observable
final class SystemLook {
    private(set) var reduceTransparency = false
    private(set) var increaseContrast = false
    private(set) var reduceMotion = false
    /// System Settings › Appearance › Liquid Glass, 0 = clear … 1 = tinted.
    /// Undocumented NSGlobalDomain key found in Phase 0; nil if absent.
    private(set) var glassTint: Double?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tintObserver: DefaultsKeyObserver?

    init() {
        refresh()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        tintObserver = DefaultsKeyObserver(key: "NSGlassTintAmount") { [weak self] in self?.refresh() }
    }

    /// Re-reads everything. Also called when the island opens, as a fallback
    /// for the rare slider change KVO misses.
    func refresh() {
        let ws = NSWorkspace.shared
        if reduceTransparency != ws.accessibilityDisplayShouldReduceTransparency { reduceTransparency.toggle() }
        if increaseContrast != ws.accessibilityDisplayShouldIncreaseContrast { increaseContrast.toggle() }
        if reduceMotion != ws.accessibilityDisplayShouldReduceMotion { reduceMotion.toggle() }
        let tint = UserDefaults.standard.object(forKey: "NSGlassTintAmount") as? Double
        if tint != glassTint { glassTint = tint }
    }

    /// How far the Hybrid collar takes to fade from black into glass. Clearer
    /// glass gets a longer fade so the edge doesn't look like a hard line.
    func collarFade(open: Bool) -> CGFloat {
        guard open else { return 8 }
        let clarity = 1 - (glassTint ?? 0.5)
        return 16 + 14 * clarity
    }
}

/// String-keyed KVO on UserDefaults.standard (which includes NSGlobalDomain).
final class DefaultsKeyObserver: NSObject {
    private let key: String
    private let onChange: () -> Void

    init(key: String, onChange: @escaping () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    isolated deinit { UserDefaults.standard.removeObserver(self, forKeyPath: key) }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.onChange() }
    }
}
