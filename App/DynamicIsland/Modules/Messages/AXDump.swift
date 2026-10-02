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

    /// Every banner on screen and its actions, in full.
    static func bannerActions() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return "-" }
        return NotificationBannerReader.banners(pid: app.processIdentifier).map { b in
            var names: CFArray?
            AXUIElementCopyActionNames(b.element, &names)
            let actions = ((names as? [String]) ?? []).map { name -> String in
                var desc: CFString?
                AXUIElementCopyActionDescription(b.element, name as CFString, &desc)
                return "[\(name.replacingOccurrences(of: "\n", with: " | "))] = \(desc as String? ?? "")"
            }
            return "\(b.appName): " + actions.joined(separator: " ; ")
        }.joined(separator: "\n")
    }

    /// Performs the named action (its "Name:…" form) on the newest banner.
    static func perform(_ named: String) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let b = NotificationBannerReader.banners(pid: app.processIdentifier).last else { return "no banner" }
        var names: CFArray?
        AXUIElementCopyActionNames(b.element, &names)
        guard let action = ((names as? [String]) ?? []).first(where: { $0.contains("Name:\(named)") || $0 == named }) else { return "no action \(named)" }
        return "\(named): \(AXUIElementPerformAction(b.element, action as CFString).rawValue)"
    }

    /// Opens Notification Center (presses the menu bar clock), looks for `text`
    /// in what it lists, then closes it again.
    static func historyContains(_ text: String, clearing: Bool = false) async -> String {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return "no Control Center" }
        _ = cc
        // The clock is the menu bar's rightmost item.
        let width = NSScreen.screens.first?.frame.width ?? 1512
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(width - 30), 12, &hit)
        guard let clock = hit else { return "nothing at the clock" }
        let what = "\(string(clock, kAXRoleAttribute)) \(string(clock, kAXIdentifierAttribute)) \(string(clock, kAXDescriptionAttribute)) \(string(clock, kAXTitleAttribute))"
        guard what.lowercased().contains("clock") || string(clock, kAXIdentifierAttribute).contains("menuextra") else { return "not the clock: " + what }
        AXUIElementPerformAction(clock, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(900))
        var all = ""
        if let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            for w in children(AXUIElementCreateApplication(nc.processIdentifier), kAXWindowsAttribute) where string(w, kAXSubroleAttribute) == "AXSystemDialog" {
                dump(w, depth: 0, into: &all)
            }
        }
        if clearing, let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            // Close each notification that mentions the text (only ours, from the tests).
            var closed = 0
            for _ in 0..<12 {
                guard let hit = find(AXUIElementCreateApplication(nc.processIdentifier), depth: 0, where: {
                    string($0, kAXSubroleAttribute).hasPrefix("AXNotificationCenter") && string($0, kAXDescriptionAttribute).contains(text)
                }) else { break }
                var names: CFArray?
                AXUIElementCopyActionNames(hit, &names)
                guard let close = ((names as? [String]) ?? []).first(where: { $0.hasPrefix("Name:Close") || $0.hasPrefix("Name:Clear") }) else { break }
                AXUIElementPerformAction(hit, close as CFString)
                closed += 1
                try? await Task.sleep(for: .milliseconds(350))
            }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
            return "closed \(closed) notification(s) mentioning \"\(text)\""
        }
        AXUIElementPerformAction(clock, kAXPressAction as CFString)
        let found = all.contains(text)
        return "\(found ? "FOUND" : "not found") \"\(text)\" in Notification Center (\(all.components(separatedBy: "AXNotificationCenter").count - 1) notification elements)"
    }

    private static func find(_ e: AXUIElement, depth: Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(e) { return e }
        guard depth < 8 else { return nil }
        for c in children(e, kAXChildrenAttribute) { if let f = find(c, depth: depth + 1, where: match) { return f } }
        return nil
    }

    private static func children(_ e: AXUIElement, _ key: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
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
