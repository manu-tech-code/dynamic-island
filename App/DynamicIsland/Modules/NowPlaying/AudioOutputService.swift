import AudioToolbox
import CoreAudio
import Observation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    /// What a built-in output plays through now: the speakers, or headphones in the jack.
    var dataSource: UInt32?

    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate }

    /// The icon, from how the output is connected rather than its name, which
    /// macOS translates for built-in outputs. A Bluetooth device's name comes
    /// from its maker, the same in every language, so product names still help.
    var symbolName: String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("beats") { return "beats.headphones" }
            return n.contains("speaker") ? "hifispeaker.fill" : "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeBuiltIn:
            if dataSource == Self.headphonesSource { return "headphones" }
            return Self.isLaptop ? "laptopcomputer" : "desktopcomputer"
        default: return "waveform"
        }
    }

    /// The built-in output's headphone jack ('hdpn').
    static let headphonesSource: UInt32 = 0x6864_706E
    /// A Mac with a battery is a laptop; the others' speakers are in a desktop.
    private static let isLaptop = BatteryService.read().hasBattery
}

/// System sound output: the device list, which one is the default, and its volume.
/// All public CoreAudio, pushed by property listeners; no permissions needed.
@Observable
final class AudioOutputService {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultID: AudioDeviceID = 0
    /// 0…1, nil when the device has no software volume (some HDMI outputs).
    private(set) var volume: Float?
    private(set) var muted = false
    /// Called when the volume or mute state changes from anywhere (keys,
    /// Control Center, another app); drives the island's volume HUD.
    @ObservationIgnored var onVolumeChange: ((Float, Bool) -> Void)?
    @ObservationIgnored private var muteListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var volumeListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    var current: AudioOutputDevice? { devices.first { $0.id == defaultID } }

    /// The output's volume can be changed from here. Some displays and audio
    /// interfaces have no software volume; their keys are left to macOS.
    var canSetVolume: Bool { Self.settable(defaultID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) }
    var canMute: Bool { Self.settable(defaultID, kAudioDevicePropertyMute) }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        devices = Self.outputDevices().sorted { a, b in
            if a.isVirtual != b.isVirtual { return !a.isVirtual }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let def = Self.uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        if def != defaultID { defaultID = def; watchVolume(of: def) }
        volume = Self.volume(of: def)
        muted = Self.mute(of: def) ?? false
    }

    func setMuted(_ on: Bool) {
        var v: UInt32 = on ? 1 : 0
        var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(defaultID, &addr) else { return }
        if AudioObjectSetPropertyData(defaultID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr { muted = on }
    }

    func select(_ device: AudioOutputDevice) {
        var id = device.id
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr { Log.error("set default output to \(device.name) failed: \(status)") }
        refresh()
    }

    func setVolume(_ value: Float) {
        var v = max(0, min(1, value))
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        let status = AudioObjectSetPropertyData(defaultID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if status == noErr { volume = v }
    }

    private func watchVolume(of device: AudioDeviceID) {
        var volAddr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if let old = volumeListener { AudioObjectRemovePropertyListenerBlock(old.device, &volAddr, .main, old.block); volumeListener = nil }
        if let old = muteListener { AudioObjectRemovePropertyListenerBlock(old.device, &muteAddr, .main, old.block); muteListener = nil }
        guard device != 0 else { return }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.volume = Self.volume(of: device)
                self.muted = Self.mute(of: device) ?? false
                if let v = self.volume { self.onVolumeChange?(v, self.muted) }
            }
        }
        if AudioObjectAddPropertyListenerBlock(device, &volAddr, .main, changed) == noErr { volumeListener = (device, changed) }
        if AudioObjectHasProperty(device, &muteAddr), AudioObjectAddPropertyListenerBlock(device, &muteAddr, .main, changed) == noErr {
            muteListener = (device, changed)
        }
    }

    /// Has the property and can set it. If Core Audio can't say, it's taken as settable.
    private static func settable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        guard id != 0 else { return false }
        var addr = address(selector, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = true
        return AudioObjectIsPropertySettable(id, &addr, &settable) != noErr || settable.boolValue
    }

    private static func mute(of id: AudioDeviceID) -> Bool? {
        guard id != 0 else { return nil }
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func name(_ id: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Output \(id)" }
        return n.takeRetainedValue() as String
    }

    private static func volume(of id: AudioDeviceID) -> Float? {
        guard id != 0 else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            return AudioOutputDevice(id: id, name: name(id), transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                                     dataSource: uint32(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput))
        }
    }
}
