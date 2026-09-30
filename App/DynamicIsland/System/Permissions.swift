import AppKit
import CoreServices

/// Automation (Apple Events) permission for a target app, checked without prompting.
enum AutomationPermission: Equatable {
    case granted, denied, notDetermined, appNotRunning, unknown

    static func status(for bundleID: String) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .appNotRunning
        default: return .unknown
        }
    }

    /// Shows the system prompt if needed. The target app must be running.
    static func request(for bundleID: String) async -> AutomationPermission {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            if let desc = target.aeDesc { _ = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true) }
        }.value
        return status(for: bundleID)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        case .appNotRunning: "Open the app to check"
        case .unknown: "Unknown"
        }
    }
}
