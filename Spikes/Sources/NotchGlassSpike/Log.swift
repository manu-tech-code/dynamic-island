import Foundation

/// Appends to ~/Library/Logs/IslandSpikes/NotchGlass.log and echoes to stdout.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/IslandSpikes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("NotchGlass.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
