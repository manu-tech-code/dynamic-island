import Foundation
import Observation

/// Your Shortcuts, listed and run through the `shortcuts` command-line tool.
/// The list is only read when Settings shows it: the dashboard's widget runs
/// pinned shortcuts by name and doesn't need it.
@Observable
final class ShortcutsService {
    private(set) var all: [String] = []
    private(set) var running: Set<String> = []
    private(set) var lastError: String?
    @ObservationIgnored private var loaded = false

    /// Reads the list the first time it's needed.
    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    func reload() {
        loaded = true
        Task {
            let out = await Self.run(["list"])
            all = (out?.output ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    func run(_ name: String) {
        guard !running.contains(name) else { return }
        running.insert(name)
        lastError = nil
        Log.info("shortcut: running \(private: name)")
        Task {
            let result = await Self.run(["run", name])
            running.remove(name)
            if let result, result.status != 0 {
                lastError = "“\(name)” didn’t finish"
                Log.error("shortcut \(private: name) failed (\(result.status)): \(private: result.errorOutput)")
            }
        }
    }

    private struct Result: Sendable { let status: Int32; let output: String; let errorOutput: String }

    /// Runs the tool on a background thread, reading its output while it runs:
    /// a pipe holds only 64 KB, and a tool blocked on a full one never exits.
    nonisolated private static func run(_ args: [String]) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { continuation.resume(returning: nil); return }
                // Both at once: either can fill while the other is being read.
                let errorData = DataBox()
                let group = DispatchGroup()
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    errorData.data = err.fileHandleForReading.readDataToEndOfFile()
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                continuation.resume(returning: Result(status: p.terminationStatus, output: String(decoding: o, as: UTF8.self),
                                                      errorOutput: String(decoding: errorData.data, as: UTF8.self)))
            }
        }
    }
}

/// Filled on one thread and read on another after the group's wait, which orders them.
nonisolated private final class DataBox: @unchecked Sendable {
    var data = Data()
}
