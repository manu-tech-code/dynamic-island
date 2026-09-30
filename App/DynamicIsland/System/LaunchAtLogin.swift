import ServiceManagement

/// Open at login through SMAppService. The system owns this state, so it is
/// read from there rather than stored in settings.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.error("launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
