import Foundation
import Observation

/// Your Shortcuts, listed and run through the `shortcuts` command-line tool.
@Observable
final class ShortcutsService {
    private(set) var all: [String] = []
    private(set) var running: Set<String> = []
    private(set) var lastError: String?

    func reload() {
        Task {
            let out = await Self.run(["list"])
            all = (out?.output ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    func run(_ name: String) {
        guard !running.contains(name) else { return }
        running.insert(name)
        lastError = nil
        Log.info("shortcut: running \(name)")
        Task {
            let result = await Self.run(["run", name])
            running.remove(name)
            if let result, result.status != 0 {
                lastError = "“\(name)” didn’t finish"
                Log.error("shortcut \(name) failed: \(result.errorOutput)")
            }
        }
    }

    private struct Result: Sendable { let status: Int32; let output: String; let errorOutput: String }

    nonisolated private static func run(_ args: [String]) async -> Result? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: Result(status: proc.terminationStatus, output: o, errorOutput: e))
            }
            do { try p.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
