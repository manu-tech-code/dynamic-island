import AudioToolbox
import CoreAudio
import Foundation
import IslandCore
import Synchronization

/// The music's loudness, band by band, for the waveform's bars (Settings ›
/// Now Playing › Waveform follows the music). It listens to what the Mac is
/// playing through a Core Audio tap, which needs System Audio Recording
/// permission and shows macOS's purple dot while it runs. It runs only while a
/// moving waveform is on screen (`acquire`/`release`), and the sound is only
/// measured: nothing is kept or sent anywhere.
final class AudioLevelService {
    /// Written on the audio thread, read by the bars every frame.
    let levels = SharedLevels()
    private var demand = 0
    private var tap: SystemAudioTap?
    private var stopTask: Task<Void, Never>?

    init() {
        // A new output (AirPods connecting): the tap goes with the old one, so start over.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.tap != nil else { return }
                self.stop()
                self.start()
            }
        }
    }

    func acquire() {
        demand += 1
        stopTask?.cancel()
        stopTask = nil
        if tap == nil { start() }
    }

    func release() {
        demand = max(0, demand - 1)
        guard demand == 0, stopTask == nil else { return }
        // Some grace, so the island coming out, an alert or the next song doesn't
        // restart the tap (and blink macOS's purple dot off and on).
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.demand == 0 else { return }
            self.stopTask = nil
            self.stop()
        }
    }

    private func start() {
        do {
            tap = try SystemAudioTap(levels: levels)
            Log.info("audio levels: listening")
        } catch {
            Log.error("audio levels: \(error)")
        }
    }

    private func stop() {
        tap?.invalidate()
        tap = nil
        levels.reset()
        Log.info("audio levels: stopped")
    }

    #if DEBUG
    var debugDescription: String {
        let s = levels.snapshot()
        return "running \(tap != nil), demand \(demand), hearing \(s.hearing), bands \(s.bands.map { String(format: "%.2f", $0) })"
    }
    #endif
}

/// The bars' heights, shared between the audio thread and the bars.
nonisolated final class SharedLevels: Sendable {
    struct Snapshot {
        var bands: [Float]
        /// Heard something in the last three seconds. A tap without permission
        /// hears only exact silence, so the bars fall back to moving on their own.
        var hearing: Bool
    }

    private struct State {
        var bands = [Float](repeating: 0, count: AudioBands.count)
        var soundAt: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    func publish(_ bands: [Float], sound: Bool) {
        state.withLock {
            $0.bands = bands
            if sound { $0.soundAt = .now }
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { s in
            Snapshot(bands: s.bands, hearing: s.soundAt.map { ContinuousClock.now - $0 < .seconds(3) } ?? false)
        }
    }

    func reset() { state.withLock { $0 = State() } }
}

struct AudioTapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "couldn't \(step) (\(status))" }
}

/// A Core Audio tap on everything the Mac plays except this app, as the input
/// of a private aggregate device, with an IO block that measures it.
nonisolated private final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.dynamicisland.audio-levels", qos: .userInteractive)

    init(levels: SharedLevels) throws {
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
            description.uuid = UUID()
            description.name = "Dynamic Island waveform"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the tap")

            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Dynamic Island waveform",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the device")

            let format = try Self.format(of: tapID)
            guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw AudioTapError(step: "read the tap's format", status: OSStatus(format.mFormatFlags))
            }
            let analyzer = BandAnalyzer(sampleRate: format.mSampleRate, levels: levels)
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                analyzer.consume(input)
            }, "listen")
            try Self.check(AudioDeviceStart(aggregateID, procID), "start")
        } catch {
            invalidate()
            throw error
        }
    }

    func invalidate() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioTapError(step: step, status: status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// This app's own audio, left out so its sounds don't move the bars.
    private static func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device), "find the output")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a = address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid), "read the output's id")
        guard let uid else { throw AudioTapError(step: "read the output's id", status: -1) }
        return uid.takeRetainedValue() as String
    }

    private static func format(of tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &format), "read the tap's format")
        return format
    }
}

/// Mixes each block the tap delivers down to mono and measures it. Only ever
/// used on the tap's own queue, one block after another.
nonisolated private final class BandAnalyzer: @unchecked Sendable {
    private let bands: AudioBands
    private let levels: SharedLevels
    private var mono: [Float] = []

    init(sampleRate: Double, levels: SharedLevels) {
        bands = AudioBands(sampleRate: sampleRate)
        self.levels = levels
    }

    func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mData != nil else { return }
        mono.removeAll(keepingCapacity: true)
        if buffers.count == 1 {
            // Interleaved: L R L R …
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let samples = first.mData!.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                mono.append(sum / Float(channels))
            }
        } else {
            // One buffer per channel.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for f in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { mono[f] += samples[f] }
            }
            let n = Float(buffers.count)
            for f in 0..<frames { mono[f] /= n }
        }
        if bands.process(mono) { levels.publish(bands.levels, sound: !bands.isDigitalSilence) }
    }
}
