import Foundation
import Testing
@testable import IslandCore

@Suite struct GPUSampleTests {
    @Test func readsTheLoadAndMemoryAppleSiliconReports() throws {
        // As read from an M5's AGXAccelerator.
        let stats: [String: Any] = ["Device Utilization %": 29, "Renderer Utilization %": 28, "Tiler Utilization %": 13,
                                    "In use system memory": 881_557_504, "Alloc system memory": 4_999_938_048]
        let sample = try #require(GPUSample(performanceStatistics: stats))
        #expect(sample.utilization == 0.29)
        #expect(sample.memoryInUse == 881_557_504)
    }

    @Test func fallsBackToTheRendererAndKeepsTheLoadInRange() throws {
        let renderer = try #require(GPUSample(performanceStatistics: ["Renderer Utilization %": NSNumber(value: 64)]))
        #expect(renderer.utilization == 0.64)
        #expect(renderer.memoryInUse == nil)
        #expect(GPUSample(performanceStatistics: ["Device Utilization %": 140])?.utilization == 1)
        #expect(GPUSample(performanceStatistics: ["Device Utilization %": -3])?.utilization == 0)
    }

    @Test func noLoadNoSample() {
        #expect(GPUSample(performanceStatistics: [:]) == nil)
        #expect(GPUSample(performanceStatistics: ["In use system memory": 1024]) == nil)
        #expect(GPUSample(performanceStatistics: ["Device Utilization %": "busy"]) == nil)
    }
}
