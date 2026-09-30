// Spike 4: which clipboard calls trigger macOS's "Allow paste?" alert?
//
//   ClipboardSpike [--read] [--watch <seconds>]
//
// Always runs the calls Apple documents as alert-free (changeCount, types,
// detection). With --read it also reads the string, which is the call that may
// alert. Contents are never printed: only types, lengths and timings.

import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
let doRead = argv.contains("--read")
let watchSeconds: Double = {
    if let i = argv.firstIndex(of: "--watch"), i + 1 < argv.count { return Double(argv[i + 1]) ?? 0 }
    return 0
}()

func behaviorName(_ b: NSPasteboard.AccessBehavior) -> String {
    switch b {
    case .default: return "default (never alerted yet)"
    case .ask: return "ask"
    case .alwaysAllow: return "alwaysAllow"
    case .alwaysDeny: return "alwaysDeny"
    @unknown default: return "unknown(\(b.rawValue))"
    }
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let t = Date()
    let v = try body()
    print(String(format: "  %-34@ %6.0f ms", label as NSString, -t.timeIntervalSinceNow * 1000))
    return v
}

func probe(read: Bool) async {
    let pb = NSPasteboard.general
    print("accessBehavior: \(behaviorName(pb.accessBehavior))")
    let count = timed("changeCount") { pb.changeCount }
    print("    = \(count)")
    let types = timed("types") { pb.types ?? [] }
    print("    = \(types.map(\.rawValue).prefix(8).joined(separator: ", "))")
    do {
        let t = Date()
        let pats = try await pb.detectedPatterns(for: [\.probableWebURL, \.number, \.probableWebSearch])
        print(String(format: "  %-34@ %6.0f ms", "detectedPatterns" as NSString, -t.timeIntervalSinceNow * 1000))
        let names = pats.map { kp -> String in
            if kp == \NSPasteboard.DetectedValues.probableWebURL { return "webURL" }
            if kp == \NSPasteboard.DetectedValues.number { return "number" }
            if kp == \NSPasteboard.DetectedValues.probableWebSearch { return "webSearch" }
            return "other"
        }
        print("    = [\(names.sorted().joined(separator: ", "))]")
    } catch { print("  detectedPatterns error: \(error)") }
    do {
        let t = Date()
        let meta = try await pb.detectedMetadata(for: [\.contentType])
        print(String(format: "  %-34@ %6.0f ms", "detectedMetadata(contentType)" as NSString, -t.timeIntervalSinceNow * 1000))
        print("    = \(meta.contentType?.identifier ?? "nil")")
    } catch { print("  detectedMetadata error: \(error)") }
    if read {
        let s = timed("string(forType: .string)  <- may alert") { pb.string(forType: .string) }
        print("    = \(s.map { "\($0.count) characters (content not shown)" } ?? "nil (denied or no text)")")
        print("accessBehavior after read: \(behaviorName(pb.accessBehavior))")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("ClipboardSpike · bundle \(Bundle.main.bundleIdentifier ?? "none") · read=\(doRead) watch=\(Int(watchSeconds))s")

Task { @MainActor in
    await probe(read: doRead)
    if watchSeconds > 0 {
        print("\nwatching changeCount for \(Int(watchSeconds)) s (copy something to test)…")
        var last = NSPasteboard.general.changeCount
        let end = Date().addingTimeInterval(watchSeconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(500))
            let now = NSPasteboard.general.changeCount
            if now != last {
                last = now
                print("\nchange detected (changeCount \(now))")
                await probe(read: doRead)
            }
        }
    }
    print("\ndone")
    exit(0)
}
app.run()
