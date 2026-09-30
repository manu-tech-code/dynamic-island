import CoreAudio
import CoreMediaIO
import IslandCore
import Observation

/// Whether any app is using the microphone or a camera, from CoreAudio and
/// CoreMediaIO "running somewhere" flags. Reading them needs no permission
/// and doesn't touch the devices.
@Observable
final class PrivacyIndicatorService: ActivityProvider {
    let kind = ActivityKind.privacy
    private(set) var microphone = false
    private(set) var camera = false
    private(set) var since: Date?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var inputDevice: AudioDeviceID = 0
    @ObservationIgnored private var micBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var cameraDevices: [CMIOObjectID] = []
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
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchInput() }
        }
        watchInput()
        watchCameras()
    }

    // MARK: microphone

    private func watchInput() {
        var runningAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let old = micBlock, inputDevice != 0 {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &runningAddr, .main, old)
        }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &size, &id)
        inputDevice = id
        guard id != 0 else { set(mic: false); return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readMic() }
        }
        micBlock = block
        AudioObjectAddPropertyListenerBlock(id, &runningAddr, .main, block)
        readMic()
    }

    private func readMic() {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(inputDevice, &addr, 0, nil, &size, &running)
        set(mic: running != 0)
    }

    // MARK: camera

    private func watchCameras() {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0, size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0 else { return }
        cameraDevices = devices
        var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        for d in devices {
            CMIOObjectAddPropertyListenerBlock(d, &running, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.readCameras() }
            }
        }
        readCameras()
    }

    private func readCameras() {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        let any = cameraDevices.contains { d in
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
}
