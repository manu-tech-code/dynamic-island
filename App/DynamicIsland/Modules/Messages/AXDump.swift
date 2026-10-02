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

    /// Performs the named action (its "Name:…" form) on the newest banner, or a
    /// scroll on the scroll area holding it (`scroll:AXScrollRightByPage`).
    static func perform(_ named: String) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let b = NotificationBannerReader.banners(pid: app.processIdentifier).last else { return "no banner" }
        if named.hasPrefix("scroll:") {
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(b.element, kAXParentAttribute as CFString, &parent)
            guard let area = parent else { return "no parent" }
            let action = String(named.dropFirst(7))
            return "\(action) on \(string(area as! AXUIElement, kAXRoleAttribute)): \(AXUIElementPerformAction(area as! AXUIElement, action as CFString).rawValue)"
        }
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
        if text == "-ids", let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            var rows: [String] = []
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard depth < 12 else { return }
                if string(e, kAXSubroleAttribute).hasPrefix("AXNotificationCenter") {
                    var names: CFArray?
                    AXUIElementCopyActionNames(e, &names)
                    rows.append("\(string(e, kAXSubroleAttribute)) id=\(string(e, kAXIdentifierAttribute)) \"\(string(e, kAXDescriptionAttribute).prefix(50))\" actions=\(((names as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 })")
                }
                for c in children(e, kAXChildrenAttribute) { walk(c, depth + 1) }
            }
            for w in children(AXUIElementCreateApplication(nc.processIdentifier), kAXWindowsAttribute) where string(w, kAXSubroleAttribute) == "AXSystemDialog" { walk(w, 0) }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
            return "list:\n" + rows.joined(separator: "\n")
        }
        if text == "-tree", let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            var rows: [String] = []
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard depth < 5 else { return }
                var size: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size)
                var s = CGSize.zero
                if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
                rows.append(String(repeating: "  ", count: depth) + "\(string(e, kAXRoleAttribute))/\(string(e, kAXSubroleAttribute)) id=\(string(e, kAXIdentifierAttribute).prefix(40)) desc=\(string(e, kAXDescriptionAttribute).prefix(30)) \(Int(s.width))×\(Int(s.height))")
                for c in children(e, kAXChildrenAttribute).prefix(4) { walk(c, depth + 1) }
            }
            for w in children(AXUIElementCreateApplication(nc.processIdentifier), kAXWindowsAttribute) where string(w, kAXSubroleAttribute) == "AXSystemDialog" { walk(w, 0) }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
            return "panel tree:\n" + rows.joined(separator: "\n")
        }
        if text.hasPrefix("-where:"), let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            // Where the notification with this title sits in the list, and its parents.
            let title = String(text.dropFirst(7))
            try? await Task.sleep(for: .milliseconds(400))
            var out = "not in the list"
            func walk(_ e: AXUIElement, _ path: [String], _ depth: Int) {
                guard depth < 12 else { return }
                let me = "\(string(e, kAXRoleAttribute))/\(string(e, kAXSubroleAttribute)) id=\(string(e, kAXIdentifierAttribute).prefix(36))"
                if string(e, kAXDescriptionAttribute).contains(title), string(e, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
                    var names: CFArray?
                    AXUIElementCopyActionNames(e, &names)
                    out = (path + [me]).joined(separator: "\n  ↳ ") + "\n  actions \(((names as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 })"
                    return
                }
                for c in children(e, kAXChildrenAttribute) { walk(c, path + [me], depth + 1) }
            }
            for w in children(AXUIElementCreateApplication(nc.processIdentifier), kAXWindowsAttribute) where string(w, kAXSubroleAttribute) == "AXSystemDialog" { walk(w, [], 0) }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
            return "where:\n" + out
        }
        if text == "-windows" {
            let windows = windows()
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
            return "with the panel open: " + windows
        }
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

    /// Moves Notification Center's banner window (the AXSystemDialog one) to `y`, and reports where it is.
    static func moveBannerWindow(y: CGFloat?) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return "-" }
        guard let w = children(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute).first(where: { string($0, kAXSubroleAttribute) == "AXSystemDialog" }) else { return "no banner window" }
        var result = ""
        if let y {
            var point = CGPoint(x: 0, y: y)
            let value = AXValueCreate(.cgPoint, &point)!
            result = "set \(AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, value).rawValue); "
        }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v)
        var p = CGPoint.zero
        if let v { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        return result + "window at \(Int(p.x)),\(Int(p.y))"
    }

    /// Which of the banner's (and its window's) attributes another app may change.
    static func settable() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let b = NotificationBannerReader.banners(pid: app.processIdentifier).last else { return "no banner" }
        var out: [String] = []
        var e: AXUIElement? = b.element
        var level = 0
        while let el = e, level < 5 {
            var names: CFArray?
            AXUIElementCopyAttributeNames(el, &names)
            let writable = ((names as? [String]) ?? []).filter { name in
                var ok = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
            }
            out.append("level \(level) \(string(el, kAXRoleAttribute))/\(string(el, kAXSubroleAttribute)): \(writable)")
            var parent: CFTypeRef?
            e = AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success ? (parent as! AXUIElement) : nil
            level += 1
        }
        return out.joined(separator: "\n")
    }

    /// Every attribute and action of the newest banner and each element above it.
    static func bannerAnatomy() -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let b = NotificationBannerReader.banners(pid: app.processIdentifier).last else { return "no banner" }
        var out = ""
        var e: AXUIElement? = b.element
        var level = 0
        while let el = e, level < 6 {
            out += "— level \(level): \(string(el, kAXRoleAttribute))/\(string(el, kAXSubroleAttribute))\n"
            var names: CFArray?
            AXUIElementCopyAttributeNames(el, &names)
            for name in (names as? [String]) ?? [] where name != kAXChildrenAttribute && name != "AXChildrenInNavigationOrder" {
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(el, name as CFString, &v)
                var text = v.map { "\($0)" } ?? "nil"
                if text.count > 140 { text = String(text.prefix(140)) + "…" }
                out += "   \(name) = \(text.replacingOccurrences(of: "\n", with: " "))\n"
            }
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            out += "   actions: \(((actions as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 })\n"
            var parent: CFTypeRef?
            e = AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success ? (parent as! AXUIElement) : nil
            level += 1
        }
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
