import Darwin
import Foundation
import IOKit
import IslandCore
import Observation

/// CPU, GPU, memory, storage and network for the dashboard. Samples only while
/// something on screen asks for it (`acquire`/`release`), so a closed
/// dashboard costs nothing.
@Observable
final class SystemStatsService {
    enum Pressure { case normal, warning, critical }

    static let historyLength = 40

    private(set) var cpu: Double = 0
    private(set) var cpuHistory: [Double] = []
    /// GPU load, 0…1; nil until read, or where the GPU doesn't report it.
    private(set) var gpu: Double?
    private(set) var gpuHistory: [Double] = []
    private(set) var gpuMemoryUsed: UInt64?
    /// The GPU's cores, read once (Apple silicon reports them).
    private(set) var gpuCores: Int?
    private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var memoryPressure: Pressure = .normal
    private(set) var memoryHistory: [Double] = []
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    private(set) var netIn: Double = 0
    private(set) var netOut: Double = 0
    private(set) var netInHistory: [Double] = []
    private(set) var netOutHistory: [Double] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    @ObservationIgnored private var lastDiskRead = Date.distantPast

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }

    func acquire() {
        demand += 1
        guard demand == 1 else { return }
        sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settings.settings.systemStats.refreshSeconds ?? 1
                try? await Task.sleep(for: .seconds(interval))
                self?.sample()
            }
        }
    }

    func release() {
        demand = max(0, demand - 1)
        guard demand == 0 else { return }
        task?.cancel()
        task = nil
        lastNet = nil
    }

    private func sample() {
        if let t = Self.cpuTicks() {
            if let last = lastTicks, t.total > last.total {
                cpu = Double(t.busy - last.busy) / Double(t.total - last.total)
                push(&cpuHistory, cpu)
            }
            lastTicks = t
        }
        if let g = Self.gpuSample() {
            gpu = g.sample.utilization
            gpuMemoryUsed = g.sample.memoryInUse
            if gpuCores == nil { gpuCores = g.cores }
            push(&gpuHistory, g.sample.utilization)
        }
        if let m = Self.memory() {
            memoryUsed = m.used
            memoryPressure = m.pressure
            push(&memoryHistory, memoryFraction)
        }
        if let n = Self.networkBytes() {
            let now = Date()
            if let last = lastNet {
                let dt = max(0.1, now.timeIntervalSince(last.at))
                netIn = Double(n.inBytes &- last.inBytes) / dt
                netOut = Double(n.outBytes &- last.outBytes) / dt
                push(&netInHistory, netIn)
                push(&netOutHistory, netOut)
            }
            lastNet = (n.inBytes, n.outBytes, now)
        }
        if Date().timeIntervalSince(lastDiskRead) > 30 {
            lastDiskRead = Date()
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            diskFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(values?.volumeTotalCapacity ?? 0)
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: Mach / BSD

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// The first GPU that reports its load, from the I/O Registry (no admin rights needed).
    private static func gpuSample() -> (sample: GPUSample, cores: Int?)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let sample = GPUSample(performanceStatistics: stats) else { continue }
            let cores = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            return (sample, cores?.intValue)
        }
        return nil
    }

    /// "Memory Used" the way Activity Monitor counts it: app + wired + compressed.
    private static func memory() -> (used: UInt64, pressure: Pressure)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let pressure: Pressure = level >= 4 ? .critical : level == 2 ? .warning : .normal
        return (used, pressure)
    }

    /// Bytes in/out summed over physical interfaces (en*). 32-bit counters, so
    /// deltas use wrapping subtraction.
    private static func networkBytes() -> (inBytes: UInt64, outBytes: UInt64)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var inBytes: UInt32 = 0, outBytes: UInt32 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes &+= d.ifi_ibytes
            outBytes &+= d.ifi_obytes
        }
        return (UInt64(inBytes), UInt64(outBytes))
    }
}

enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func memory(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        switch v {
        case ..<1024: return "\(Int(v)) B/s"
        case ..<1_048_576: return String(format: "%.0f KB/s", v / 1024)
        default: return String(format: "%.1f MB/s", v / 1_048_576)
        }
    }
}
