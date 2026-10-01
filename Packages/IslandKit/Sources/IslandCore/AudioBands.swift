import Accelerate

/// How loud the music is in a few frequency bands, from bass to treble: what
/// the waveform's bars follow. Feed it blocks of mono samples as they arrive;
/// every 1024 samples (about 47 times a second at 48 kHz) it updates `levels`.
///
/// Each band is scaled to its own recent peak, so the bars move fully whether
/// the song is loud or quiet, and quiet bands don't sit flat next to the bass.
/// Bars jump up with a beat and fall back within about a quarter of a second.
public final class AudioBands {
    /// Band edges in hertz: five bands, one per bar.
    public static let edges: [Float] = [40, 150, 400, 1000, 2500, 8000]
    public static var count: Int { edges.count - 1 }

    /// 0…1 for each band.
    public private(set) var levels: [Float]
    /// The last block was exact digital silence (all zeros): what a tap hears
    /// without permission, or with nothing playing.
    public private(set) var isDigitalSilence = true

    private static let size = 1024
    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private let window: [Float]
    private let bins: [Range<Int>]
    private var pending: [Float] = []
    private var peaks: [Float]
    private var real = [Float](repeating: 0, count: AudioBands.size / 2)
    private var imag = [Float](repeating: 0, count: AudioBands.size / 2)
    private var windowed = [Float](repeating: 0, count: AudioBands.size)
    private var magnitudes = [Float](repeating: 0, count: AudioBands.size / 2)

    /// Below this a band counts as silent (about -60 dB), so hiss doesn't dance.
    private static let floor: Float = 0.001
    /// Per update: how much of the peak is kept (a three-second half-life) and of a falling bar.
    private static let peakKeep: Float = 0.995
    private static let fall: Float = 0.72

    public init(sampleRate: Double) {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        let hzPerBin = Float(sampleRate) / Float(Self.size)
        let top = Self.size / 2
        bins = (0..<Self.count).map { b in
            let lo = max(1, Int((Self.edges[b] / hzPerBin).rounded(.down)))
            let hi = min(top, max(lo + 1, Int((Self.edges[b + 1] / hzPerBin).rounded(.up))))
            return lo..<hi
        }
        levels = Array(repeating: 0, count: Self.count)
        peaks = Array(repeating: Self.floor, count: Self.count)
        pending.reserveCapacity(Self.size * 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Adds samples. Returns true when `levels` changed.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        pending.append(contentsOf: samples)
        var updated = false
        while pending.count >= Self.size {
            analyze(pending[0..<Self.size])
            pending.removeFirst(Self.size)
            updated = true
        }
        return updated
    }

    public func process(_ samples: [Float]) -> Bool {
        samples.withUnsafeBufferPointer { process($0) }
    }

    private func analyze(_ block: ArraySlice<Float>) {
        isDigitalSilence = block.allSatisfy { $0 == 0 }
        vDSP.multiply(block, window, result: &windowed)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP.squareMagnitudes(split, result: &magnitudes)
            }
        }
        // A full-scale sine comes out as amplitude 1: the FFT's ×2, the window's ×½, and N/2.
        let scale = 2 / Float(Self.size)
        for (b, range) in bins.enumerated() {
            var peak: Float = 0
            for i in range { peak = max(peak, magnitudes[i]) }
            let amplitude = peak.squareRoot() * scale
            peaks[b] = max(amplitude, peaks[b] * Self.peakKeep, Self.floor)
            let target = amplitude <= Self.floor ? 0 : (amplitude / peaks[b]).squareRoot()
            levels[b] = max(target, levels[b] * Self.fall)
        }
    }
}
