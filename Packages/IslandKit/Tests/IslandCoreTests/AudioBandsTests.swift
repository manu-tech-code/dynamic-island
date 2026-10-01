import Foundation
import Testing
@testable import IslandCore

@Suite struct AudioBandsTests {
    let rate = 48_000.0

    func tone(_ hz: Double, seconds: Double = 0.5, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test func fiveBarsFromBassToTreble() {
        #expect(AudioBands.count == 5)
        #expect(AudioBands(sampleRate: rate).levels == [0, 0, 0, 0, 0])
    }

    @Test func aBassNoteMovesOnlyTheFirstBar() throws {
        let bands = AudioBands(sampleRate: rate)
        #expect(bands.process(tone(90)))
        let l = bands.levels
        #expect(l[0] > 0.9)
        #expect(l[2...].allSatisfy { $0 < 0.05 })
        #expect(!bands.isDigitalSilence)
    }

    @Test func aHighNoteMovesOnlyTheLastBar() {
        let bands = AudioBands(sampleRate: rate)
        bands.process(tone(5_000))
        let l = bands.levels
        #expect(l[4] > 0.9)
        #expect(l[...2].allSatisfy { $0 < 0.05 })
    }

    @Test func quietMusicStillMovesTheBars() {
        // Scaled to each band's recent peak: a quiet song fills the bars too.
        let bands = AudioBands(sampleRate: rate)
        bands.process(tone(600, amplitude: 0.02))
        #expect(bands.levels[2] > 0.9)
    }

    @Test func silenceIsFlatAndNoticed() {
        let bands = AudioBands(sampleRate: rate)
        bands.process(tone(90))
        // After the music stops the bars fall within a quarter of a second.
        bands.process([Float](repeating: 0, count: Int(rate * 0.25)))
        #expect(bands.levels.allSatisfy { $0 < 0.05 })
        #expect(bands.isDigitalSilence)
    }

    @Test func waitsForAWholeBlock() {
        let bands = AudioBands(sampleRate: rate)
        #expect(!bands.process(Array(tone(90).prefix(1000))))
        #expect(bands.process(Array(tone(90).prefix(100))))
    }
}
