import AppKit
import Combine

/// Everything the app can observe about the user's appearance settings, plus
/// discovery probes for the Liquid Glass slider (which has no public API):
/// a distributed-notification sniffer and a diff of the global defaults domain.
final class SystemLook: ObservableObject {
    @Published var reduceTransparency = false
    @Published var increaseContrast = false
    @Published var reduceMotion = false
    @Published var differentiateWithoutColor = false
    @Published var appearance = "?"
    @Published var accentHex = "?"
    @Published var lastChange = "none yet"
    /// Liquid Glass slider (System Settings › Appearance), 0 = clear … 1 = tinted.
    /// Undocumented NSGlobalDomain key found by this spike's defaults diff.
    @Published var glassTint = "?"

    private var observers: [NSObjectProtocol] = []
    private var tintObserver: DefaultsKeyObserver?
    private var appearanceKVO: NSKeyValueObservation?
    private var defaultsTimer: Timer?
    private var lastDefaults: [String: [String: String]] = [:]
    private var sniffCounts: [String: Int] = [:]
    private let watchedDomains = [UserDefaults.globalDomain, "com.apple.universalaccess", "com.apple.WindowManager"]

    init() {
        refresh(reason: "launch")
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(reason: "accessibilityDisplayOptionsDidChange")
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(reason: "systemColorsDidChange")
        })
        appearanceKVO = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh(reason: "effectiveAppearance KVO") }
        }
        // Sniff every distributed notification to discover what (if anything)
        // is broadcast when the Liquid Glass slider moves.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: nil, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let name = n.name.rawValue
            self.sniffCounts[name, default: 0] += 1
            if self.sniffCounts[name]! <= 3 {
                Log.write("DISTRIBUTED \(name) object=\(n.object.map { "\($0)" } ?? "nil") userInfoKeys=\(n.userInfo?.keys.map { "\($0)" }.sorted() ?? [])")
            }
        })
        // Push test: does KVO on the key fire when System Settings changes it,
        // or do we have to poll? Each KVO hit is logged as "KVO".
        tintObserver = DefaultsKeyObserver(key: "NSGlassTintAmount") { [weak self] value in
            Log.write("KVO NSGlassTintAmount → \(value.map { "\($0)" } ?? "nil")")
            self?.refresh(reason: "NSGlassTintAmount KVO")
        }
        lastDefaults = snapshotDefaults()
        defaultsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.diffDefaults() }
    }

    func refresh(reason: String) {
        let ws = NSWorkspace.shared
        reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        differentiateWithoutColor = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])?.rawValue ?? NSApp.effectiveAppearance.name.rawValue
        if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            accentHex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        let tint = UserDefaults.standard.object(forKey: "NSGlassTintAmount") as? Double
        glassTint = tint.map { String(format: "%.2f", $0) } ?? "unset"
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lastChange = "\(f.string(from: Date())) · \(reason)"
        Log.write("LOOK [\(reason)] reduceTransparency=\(reduceTransparency) increaseContrast=\(increaseContrast) reduceMotion=\(reduceMotion) appearance=\(appearance) accent=\(accentHex) glassTint=\(glassTint)")
    }

    private func snapshotDefaults() -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for d in watchedDomains {
            let dict = UserDefaults.standard.persistentDomain(forName: d) ?? [:]
            out[d] = dict.mapValues { String(describing: $0).prefix(160).description }
        }
        return out
    }

    private func diffDefaults() {
        let now = snapshotDefaults()
        for (domain, keys) in now {
            let before = lastDefaults[domain] ?? [:]
            for k in Set(keys.keys).union(before.keys).sorted() where keys[k] != before[k] {
                Log.write("DEFAULTS \(domain) \(k): \(before[k] ?? "∅") → \(keys[k] ?? "∅")")
                if k == "NSGlassTintAmount" { refresh(reason: "NSGlassTintAmount poll") }
            }
        }
        lastDefaults = now
    }
}

/// String-keyed KVO on UserDefaults.standard (which includes NSGlobalDomain).
final class DefaultsKeyObserver: NSObject {
    let key: String
    let onChange: (Any?) -> Void

    init(key: String, onChange: @escaping (Any?) -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit { UserDefaults.standard.removeObserver(self, forKeyPath: key) }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let value = change?[.newKey]
        DispatchQueue.main.async { self.onChange(value) }
    }
}
