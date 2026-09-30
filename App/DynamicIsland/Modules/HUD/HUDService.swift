import AppKit
import ApplicationServices
import IslandCore
import Observation

/// The island's volume and brightness HUD.
///
/// Without any permission it shows whenever the output volume changes. With
/// Accessibility allowed and "Replace the system HUD" on, an event tap takes
/// over the volume, mute and brightness keys, so macOS doesn't draw its own.
@Observable
final class HUDService {
    enum TapState: Equatable { case off, needsPermission, active, failed }

    private(set) var tapState: TapState = .off
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var brightness: Float?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let audio: AudioOutputService
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var trustPoll: Task<Void, Never>?
    @ObservationIgnored private var suppressVolumeHUDUntil = Date.distantPast
    @ObservationIgnored fileprivate static weak var current: HUDService?

    init(settings: SettingsStore, engine: ActivityEngine, audio: AudioOutputService) {
        self.settings = settings
        self.engine = engine
        self.audio = audio
    }

    func start() {
        Self.current = self
        audio.onVolumeChange = { [weak self] level, muted in self?.volumeChanged(level: level, muted: muted) }
        brightness = Brightness.get()
        whenChanged({ [settings] in "\(settings.settings[module: .hud].enabled)-\(settings.settings.hud.replaceSystemHUD)" }) { [weak self] _ in
            self?.applySettings()
        }
        applySettings()
    }

    /// Asks macOS for Accessibility (shows the system prompt) and waits for it.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        waitForTrust()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func applySettings() {
        let s = settings.settings
        let wantTap = s[module: .hud].enabled && s.hud.replaceSystemHUD
        accessibilityTrusted = AXIsProcessTrusted()
        if wantTap && accessibilityTrusted { installTap() }
        else { removeTap(); tapState = wantTap ? .needsPermission : .off }
        if wantTap && !accessibilityTrusted { waitForTrust() }
    }

    private func waitForTrust() {
        guard trustPoll == nil else { return }
        trustPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.accessibilityTrusted = true
                    self.trustPoll = nil
                    self.applySettings()
                    return
                }
            }
        }
    }

    // MARK: HUD

    private func volumeChanged(level: Float, muted: Bool) {
        guard settings.settings.hud.showVolume, Date() > suppressVolumeHUDUntil else { return }
        showVolume(level: Double(level), muted: muted)
    }

    private func showVolume(level: Double, muted: Bool) {
        engine.showHUD(IslandAlert(kind: .hud, style: .volume(level: level, muted: muted, output: audio.current?.name ?? "Output"), holdSeconds: 1.6))
    }

    private func showBrightness(_ level: Double) {
        guard settings.settings.hud.showBrightness else { return }
        engine.showHUD(IslandAlert(kind: .hud, style: .brightness(level: level), holdSeconds: 1.6))
    }

    // MARK: keys

    /// Returns true when the key was handled (and should be swallowed).
    fileprivate func handle(_ press: MediaKey.Press, flags: CGEventFlags) -> Bool {
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        let steps = settings.settings.hud.steps
        switch press.key {
        case .soundUp, .soundDown:
            guard press.isDown else { return true }
            let current = Double(audio.volume ?? 0.5)
            let next = VolumeMath.step(current, up: press.key == .soundUp, steps: steps, fine: fine)
            if audio.muted { audio.setMuted(false) }
            // Our own change triggers the volume listener; show once, from here.
            suppressVolumeHUDUntil = Date().addingTimeInterval(0.25)
            audio.setVolume(Float(next))
            if settings.settings.hud.showVolume { showVolume(level: next, muted: false) }
            // macOS's "Play feedback when volume is changed"; Shift inverts it, as in macOS.
            let feedback = UserDefaults.standard.integer(forKey: "com.apple.sound.beep.feedback") == 1
            if !press.isRepeat, feedback != flags.contains(.maskShift) { NSSound(named: "Pop")?.play() }
            return true
        case .mute:
            guard press.isDown else { return true }
            suppressVolumeHUDUntil = Date().addingTimeInterval(0.25)
            audio.setMuted(!audio.muted)
            if settings.settings.hud.showVolume { showVolume(level: Double(audio.volume ?? 0), muted: audio.muted) }
            return true
        case .brightnessUp, .brightnessDown:
            guard let current = Brightness.get() else { return false } // let macOS handle it
            guard press.isDown else { return true }
            let next = VolumeMath.step(Double(current), up: press.key == .brightnessUp, steps: steps, fine: fine)
            Brightness.set(Float(next))
            brightness = Float(next)
            showBrightness(next)
            return true
        }
    }

    private func installTap() {
        guard tap == nil else { tapState = .active; return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hudTapCallback, userInfo: nil) else {
            tapState = .failed
            Log.error("HUD: event tap creation failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        tapState = .active
        Log.info("HUD: media key tap active")
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

/// Runs on the main run loop (where the tap's source was added).
nonisolated private func hudTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { HUDService.current?.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
          let press = MediaKey.decode(data1: ns.data1) else {
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let handled = MainActor.assumeIsolated { HUDService.current?.handle(press, flags: flags) ?? false }
    return handled ? nil : Unmanaged.passUnretained(event)
}

/// Built-in display brightness through DisplayServices (private, looked up at
/// runtime). Returns nil where it isn't available, e.g. an external display.
enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness"), let display = builtIn else { return nil }
        var value: Float = 0
        return unsafeBitCast(sym, to: GetFn.self)(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness"), let display = builtIn else { return }
        _ = unsafeBitCast(sym, to: SetFn.self)(display, max(0, min(1, value)))
    }
}
