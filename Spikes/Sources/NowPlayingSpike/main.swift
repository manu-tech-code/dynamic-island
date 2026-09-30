// Spike 3: can we read Now Playing on macOS 27, and which route works?
//
//   NowPlayingSpike [all|direct|perl|applescript|stream <seconds>]
//
// direct      - our own process calls MediaRemote (expected to be blocked since 15.4)
// perl        - /usr/bin/perl loads our bridge dylib and calls MediaRemote
// applescript - asks Music / Spotify directly, only if they are already running
// stream      - perl route, prints a line on every change for N seconds

import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()
let mode = args.first ?? "all"

func resourceURL(_ name: String) -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidates = [
        exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name)"), // .app
        exe.deletingLastPathComponent().appendingPathComponent(name),                                           // .build
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[1]
}

let bridgePath = resourceURL("libNowPlayingBridge.dylib").path
let scriptPath = resourceURL("np.pl").path

func appName(forPID pid: Int?) -> String {
    guard let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return "unknown" }
    return "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"))"
}

func summarize(_ label: String, _ json: String) {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("[\(label)] could not parse: \(json)")
        return
    }
    let state = (obj["state"] as? [String: Any]) ?? obj
    let info = state["info"] as? [String: Any]
    let pid = state["pid"] as? Int
    let title = info?["Title"] as? String
    let artist = info?["Artist"] as? String
    let keys = info?.keys.sorted().joined(separator: ", ") ?? "none"
    print("[\(label)] ok=\(state["ok"] ?? "?") isPlaying=\(state["isPlaying"] ?? "nil") pid=\(pid.map(String.init) ?? "nil") app=\(appName(forPID: pid)) elapsed=\(state["elapsedMs"] ?? "?")ms")
    print("[\(label)] title=\(title ?? "—") artist=\(artist ?? "—")")
    print("[\(label)] info keys: \(keys)")
}

func runDirect() {
    print("== direct: in-process MediaRemote ==")
    guard let h = dlopen(bridgePath, RTLD_NOW) else {
        print("[direct] dlopen bridge failed: \(String(cString: dlerror()))"); return
    }
    typealias Fetch = @convention(c) (Double) -> UnsafeMutablePointer<CChar>?
    guard let sym = dlsym(h, "np_fetch_json") else { print("[direct] symbol missing"); return }
    let fetch = unsafeBitCast(sym, to: Fetch.self)
    guard let c = fetch(3.0) else { print("[direct] nil"); return }
    let json = String(cString: c); free(c)
    print("[direct] raw: \(json.prefix(600))")
    summarize("direct", json)
}

@discardableResult
func runPerl(mode: String, echo: Bool) -> Int32 {
    print("== perl: /usr/bin/perl + bridge (\(mode)) ==")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [scriptPath]
    var env = ProcessInfo.processInfo.environment
    env["NP_LIB"] = bridgePath
    env["NP_MODE"] = mode
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    out.fileHandleForReading.readabilityHandler = { fh in
        let d = fh.availableData
        guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
        for line in s.split(separator: "\n") where !line.isEmpty {
            if echo { print("[perl] raw: \(line.prefix(600))") }
            summarize("perl", String(line))
        }
    }
    do { try p.run() } catch { print("[perl] launch failed: \(error)"); return -1 }
    p.waitUntilExit()
    out.fileHandleForReading.readabilityHandler = nil
    let rest = out.fileHandleForReading.readDataToEndOfFile()
    if let s = String(data: rest, encoding: .utf8), !s.isEmpty { summarize("perl", s) }
    if let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !e.isEmpty {
        print("[perl] stderr: \(e)")
    }
    print("[perl] exit status \(p.terminationStatus)")
    return p.terminationStatus
}

func runAppleScript() {
    print("== applescript: Music / Spotify (only if already running) ==")
    let players: [(String, String)] = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]
    var askedAny = false
    for (bundle, name) in players {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
            print("[applescript] \(name) is not running, skipped (we never launch it)")
            continue
        }
        askedAny = true
        let src = """
        tell application id "\(bundle)"
            set s to player state as text
            if s is "stopped" then return "stopped"
            return s & " | " & (name of current track) & " | " & (artist of current track)
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] ?? "?"
            print("[applescript] \(name) error \(code): \(err[NSAppleScript.errorMessage] ?? "")\(("\(code)" == "-1743") ? "  (Automation permission denied)" : "")")
        } else {
            print("[applescript] \(name): \(result?.stringValue ?? "no value")")
        }
    }
    if !askedAny { print("[applescript] nothing to ask") }
}

print("NowPlayingSpike on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("bundle id: \(Bundle.main.bundleIdentifier ?? "none (bare binary)")")
print("bridge: \(bridgePath)")

switch mode {
case "direct": runDirect()
case "perl": runPerl(mode: "once", echo: true)
case "applescript": runAppleScript()
case "stream":
    let secs = args.dropFirst().first ?? "20"
    runPerl(mode: "stream:\(secs)", echo: false)
default:
    runDirect(); print("")
    runPerl(mode: "once", echo: true); print("")
    runAppleScript()
}
