import Foundation

/// The GPU's load and memory, from its accelerator's "PerformanceStatistics"
/// in the I/O Registry, the numbers Activity Monitor's GPU History reads.
/// Reading them needs no admin rights.
public struct GPUSample: Equatable, Sendable {
    /// How busy the GPU is, 0…1.
    public var utilization: Double
    /// System memory the GPU is using, in bytes.
    public var memoryInUse: UInt64?

    public init(utilization: Double, memoryInUse: UInt64? = nil) {
        self.utilization = utilization
        self.memoryInUse = memoryInUse
    }

    /// nil when the dictionary has no load (a GPU that doesn't report one).
    public init?(performanceStatistics stats: [String: Any]) {
        guard let percent = Self.number(stats["Device Utilization %"]) ?? Self.number(stats["Renderer Utilization %"]) else { return nil }
        utilization = min(1, max(0, percent / 100))
        memoryInUse = Self.number(stats["In use system memory"]).map { UInt64(max(0, $0)) }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
