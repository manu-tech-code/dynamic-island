import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey. Unlike a
/// global key monitor this needs no Accessibility or Input Monitoring permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a virtual key code such as `kVK_ANSI_I`.
    ///   - modifiers: Carbon modifier flags such as `cmdKey | optionKey`.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_534C), id: id) // "DISL"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.error("RegisterEventHotKey failed: \(status)")
            return nil
        }
        Self.handlers[id] = action
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
