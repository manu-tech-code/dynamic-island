import Foundation
import os

/// Unified logging plus a plain-text copy in ~/Library/Logs/DynamicIsland,
/// which is easier to read while developing. Safe to call from any thread.
nonisolated enum Log {
    private static let logger = Logger(subsystem: "com.dynamicisland.mac", category: "app")
    private static let queue = DispatchQueue(label: "com.dynamicisland.log")
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicIsland")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DynamicIsland.log")
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    private static func append(_ line: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            let path = fileURL.path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
