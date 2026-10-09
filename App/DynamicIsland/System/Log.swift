import Foundation
import os

/// Unified logging plus a plain-text copy in ~/Library/Logs/DynamicIsland,
/// which is easier to read while developing. Safe to call from any thread.
///
/// What people play, download, name or connect is theirs: write it as
/// `\(private: title)`. The system log keeps it private (shown only where
/// private data is enabled, as when debugging), and Release builds leave it
/// out of the log file, which keeps events, counts and states.
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

    static func info(_ message: LogMessage) {
        logger.info("\(message.redacted, privacy: .public)\(message.privateSuffix, privacy: .private)")
        append("INFO  \(message.forFile)")
    }

    static func error(_ message: LogMessage) {
        logger.error("\(message.redacted, privacy: .public)\(message.privateSuffix, privacy: .private)")
        append("ERROR \(message.forFile)")
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

/// A log line with someone's own content in it marked `\(private: …)`.
nonisolated struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    /// The line with the private parts as "<private>".
    fileprivate var redacted = ""
    /// The line in full.
    fileprivate var full = ""
    private var hasPrivate = false

    init(stringLiteral value: String) {
        redacted = value
        full = value
    }

    init(stringInterpolation: Interpolation) {
        redacted = stringInterpolation.redacted
        full = stringInterpolation.full
        hasPrivate = stringInterpolation.hasPrivate
    }

    /// For the system log: the full line again, after the public one, as a private value.
    fileprivate var privateSuffix: String { hasPrivate ? " · " + full : "" }

    /// Debug builds keep everything in the file; Release builds only the public parts.
    fileprivate var forFile: String {
        #if DEBUG
        return full
        #else
        return redacted
        #endif
    }

    struct Interpolation: StringInterpolationProtocol {
        fileprivate var redacted = ""
        fileprivate var full = ""
        fileprivate var hasPrivate = false

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            redacted += literal
            full += literal
        }

        mutating func appendInterpolation(_ value: some Any) {
            appendLiteral(String(describing: value))
        }

        mutating func appendInterpolation(private value: some Any) {
            redacted += "<private>"
            full += String(describing: value)
            hasPrivate = true
        }
    }
}
