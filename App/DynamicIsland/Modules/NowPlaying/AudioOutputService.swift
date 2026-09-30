import AudioToolbox
import CoreAudio
import Observation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate }

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
        case kAudioDeviceTransportTypeBuiltIn: return n.contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "waveform"
        }
    }
}

/// System sound output: the device list, which one is the default, and its volume.
/// All public CoreAudio, pushed by property listeners; no permissions needed.
@Observable
final class AudioOutputService {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultID: AudioDeviceID = 0
    /// 0…1, nil when the device has no software volume (some HDMI outputs).
    private(set) var volume: Float?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var volumeListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    var current: AudioOutputDevice? { devices.first { $0.id == defaultID } }

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
        if let old = volumeListener {
            var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(old.device, &addr, .main, old.block)
            volumeListener = nil
        }
        guard device != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volume = Self.volume(of: device) }
        }
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectAddPropertyListenerBlock(device, &addr, .main, block) == noErr {
            volumeListener = (device, block)
        }
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
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
            return AudioOutputDevice(id: id, name: name(id), transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }
}
