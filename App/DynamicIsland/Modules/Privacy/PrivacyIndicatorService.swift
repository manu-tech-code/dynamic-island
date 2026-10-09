import CoreAudio
import CoreMediaIO
import IslandCore
import Observation

/// Whether any app is using a microphone or a camera, from CoreAudio and
/// CoreMediaIO "running" flags. Reading them needs no permission and doesn't
/// touch the devices. Every microphone and camera is watched, including ones
/// plugged in later, not only the default input.
@Observable
final class PrivacyIndicatorService: ActivityProvider {
    let kind = ActivityKind.privacy
    private(set) var microphone = false
    private(set) var camera = false
    private(set) var since: Date?

    @ObservationIgnored private let settings: SettingsStore
    /// Listeners on each input device, each app's audio, and each camera, by object.
    @ObservationIgnored private var inputBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var cameraBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var processes: [AudioObjectID] = []
    @ObservationIgnored private var started = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var activities: [Activity] {
        let s = settings.settings.privacy
        let mic = microphone && s.showMicrophone, cam = camera && s.showCamera
        guard mic || cam else { return [] }
        return [Activity(id: "privacy", kind: .privacy, payload: .privacy(PrivacyInfo(microphone: mic, camera: cam)),
                         relevance: 1, startedAt: since ?? Date())]
    }

    func start() {
        guard !started else { return }
        started = true
        // Devices plugged in or out, apps starting or stopping audio: watch the new set.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] {
            var addr = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.watchMicrophones() }
            }
        }
        watchMicrophones()
        var cameras = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameras, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchCameras() }
        }
        watchCameras()
    }

    // MARK: microphone

    private func watchMicrophones() {
        let inputs = Self.objects(kAudioHardwarePropertyDevices).filter(Self.hasInput)
        processes = Self.objects(kAudioHardwarePropertyProcessObjectList)
        watch(inputs, Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere), in: &inputBlocks)
        watch(processes, Self.address(kAudioProcessPropertyIsRunningInput), in: &processBlocks)
        readMic()
    }

    /// Listens to `property` on each of `objects`, and stops listening to ones that went.
    private func watch(_ objects: [AudioObjectID], _ property: AudioObjectPropertyAddress,
                       in blocks: inout [AudioObjectID: AudioObjectPropertyListenerBlock]) {
        var addr = property
        for (id, block) in blocks where !objects.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
            blocks[id] = nil
        }
        for id in objects where blocks[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.readMic() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr { blocks[id] = block }
        }
    }

    /// An app taking input, as macOS's own indicator counts it: per app, so a
    /// headset playing music doesn't count, and never this app (the waveform
    /// listens to the output). Where macOS doesn't list apps, any input running.
    private func readMic() {
        if processes.isEmpty {
            set(mic: inputBlocks.keys.contains { Self.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 })
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        set(mic: processes.contains { p in
            Self.uint32(p, kAudioProcessPropertyIsRunningInput) == 1
                && Self.uint32(p, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } != me
        })
    }

    // MARK: camera

    private func watchCameras() {
        let devices = Self.cameras()
        var running = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), wildcard: true)
        for (id, block) in cameraBlocks where !devices.contains(id) {
            CMIOObjectRemovePropertyListenerBlock(id, &running, .main, block)
            cameraBlocks[id] = nil
        }
        for d in devices where cameraBlocks[d] == nil {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.readCameras() }
            }
            if CMIOObjectAddPropertyListenerBlock(d, &running, .main, block) == 0 { cameraBlocks[d] = block }
        }
        readCameras()
    }

    private func readCameras() {
        var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), wildcard: true)
        let any = cameraBlocks.keys.contains { d in
            var v: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &v) == 0 && v != 0
        }
        set(camera: any)
    }

    private func set(mic: Bool? = nil, camera cam: Bool? = nil) {
        let wasActive = microphone || camera
        if let mic, mic != microphone { microphone = mic; Log.info("microphone in use: \(mic)") }
        if let cam, cam != camera { camera = cam; Log.info("camera in use: \(cam)") }
        let active = microphone || camera
        if active && !wasActive { since = Date() } else if !active { since = nil }
    }

    // MARK: CoreAudio and CoreMediaIO helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A list of objects the system object keeps (devices, or apps using audio).
    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func cameraAddress(_ selector: CMIOObjectPropertySelector, wildcard: Bool = false) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: wildcard ? CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard) : CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: wildcard ? CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard) : CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameras() -> [CMIOObjectID] {
        var addr = cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == 0 else { return [] }
        return devices
    }
}
