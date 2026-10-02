#if DEBUG
import AppKit
import ApplicationServices

/// Spike: what macOS's notification banners look like to Accessibility.
enum AXDump {
    static func notificationCenter() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return "NotificationCenter isn't running" }
        var out = "trusted \(AXIsProcessTrusted()), pid \(app.processIdentifier)\n"
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &kids)
        // Only the banners' window, not the desktop widgets.
        for w in (kids as? [AXUIElement]) ?? [] where string(w, kAXSubroleAttribute) == "AXSystemDialog" { dump(w, depth: 0, into: &out) }
        return out
    }

    /// Just the windows: title, subrole, size.
    static func windows() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return "-" }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &kids) == .success,
              let windows = kids as? [AXUIElement] else { return "no windows" }
        return windows.map { w in
            var size: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size)
            var s = CGSize.zero
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
            return "\(string(w, kAXTitleAttribute))/\(string(w, kAXSubroleAttribute)) \(Int(s.width))×\(Int(s.height))"
        }.joined(separator: " | ")
    }

    private static func dump(_ e: AXUIElement, depth: Int, into out: inout String) {
        guard depth < 14 else { return }
        var line = String(repeating: "  ", count: depth) + string(e, kAXRoleAttribute)
        for (name, key) in [("sub", kAXSubroleAttribute), ("id", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                            ("value", kAXValueAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
            let v = string(e, key)
            if !v.isEmpty { line += " \(name)=\(v.prefix(120))" }
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(e, &actions) == .success, let a = actions as? [String], !a.isEmpty { line += " actions=\(a)" }
        out += line + "\n"
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let children = kids as? [AXUIElement] else { return }
        children.forEach { dump($0, depth: depth + 1, into: &out) }
    }

    private static func string(_ e: AXUIElement, _ key: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success, let v else { return "" }
        if let s = v as? String { return s.replacingOccurrences(of: "\n", with: " ⏎ ") }
        return ""
    }
}
#endif
