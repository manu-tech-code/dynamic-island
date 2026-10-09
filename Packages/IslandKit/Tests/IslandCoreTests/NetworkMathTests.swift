import Testing
@testable import IslandCore

@Suite struct NetworkMathTests {
    let gib: UInt64 = 1 << 30

    @Test func pastFourGiBIsNoSpike() {
        // The old code summed 32-bit counters, so crossing 4 GiB looked like ~16 EB.
        let old = ["en0": InterfaceBytes(received: 4 * gib - 500, sent: 10)]
        let new = ["en0": InterfaceBytes(received: 4 * gib + 1500, sent: 30)]
        #expect(NetworkMath.moved(from: old, to: new) == InterfaceBytes(received: 2000, sent: 20))
    }

    @Test func interfacesAreComparedWithThemselves() {
        // Their sum crossing a 32-bit boundary doesn't matter either.
        let old = ["en0": InterfaceBytes(received: 3 * gib, sent: 0), "en1": InterfaceBytes(received: gib - 100, sent: 0)]
        let new = ["en0": InterfaceBytes(received: 3 * gib + 400, sent: 0), "en1": InterfaceBytes(received: gib + 100, sent: 0)]
        #expect(NetworkMath.moved(from: old, to: new).received == 600)
    }

    @Test func aResetInterfaceCountsNothing() {
        let old = ["en0": InterfaceBytes(received: 9_000, sent: 9_000), "en1": InterfaceBytes(received: 100, sent: 100)]
        let new = ["en0": InterfaceBytes(received: 50, sent: 60), "en1": InterfaceBytes(received: 300, sent: 150)]
        #expect(NetworkMath.moved(from: old, to: new) == InterfaceBytes(received: 200, sent: 50))
    }

    @Test func interfacesComingAndGoingCountNothing() {
        let old = ["en0": InterfaceBytes(received: 1_000, sent: 1_000), "en5": InterfaceBytes(received: 7 * gib, sent: gib)]
        let new = ["en0": InterfaceBytes(received: 1_500, sent: 1_100), "en7": InterfaceBytes(received: 5 * gib, sent: gib)]
        #expect(NetworkMath.moved(from: old, to: new) == InterfaceBytes(received: 500, sent: 100))
        #expect(NetworkMath.moved(from: [:], to: new) == InterfaceBytes(received: 0, sent: 0))
    }
}
