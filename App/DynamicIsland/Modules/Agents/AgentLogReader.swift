import Darwin
import Foundation
import IslandCore
import SQLite3

/// Reads the agents' own files off the main thread: the week's usage from
/// their logs (in full the first time, then only what was appended since),
/// and Codex's and OpenCode's open sessions. Only counts, times and folders
/// are read, never what was said.
actor AgentLogReader {
    struct Snapshot: Sendable {
        var ledger: AgentLedger
        /// Codex's and OpenCode's open sessions (Claude Code's come from its status files).
        var sessions: [AgentSession]
    }

    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path
    nonisolated static let claudeProjects = home + "/.claude/projects"
    nonisolated static let claudeSessions = home + "/.claude/sessions"
    nonisolated static let codexSessions = home + "/.codex/sessions"
    nonisolated static let openCodeFolder = home + "/.local/share/opencode"
    nonisolated static let openCodeDB = openCodeFolder + "/opencode.db"
    nonisolated static let geminiHistory = home + "/.gemini/antigravity-cli/history.jsonl"

    /// Which agents are on this Mac: the files they keep exist.
    nonisolated static func installed() -> Set<AgentKind> {
        let fm = FileManager.default
        var found: Set<AgentKind> = []
        if fm.fileExists(atPath: claudeProjects) || fm.fileExists(atPath: claudeSessions) { found.insert(.claudeCode) }
        if fm.fileExists(atPath: codexSessions) { found.insert(.codex) }
        if fm.fileExists(atPath: openCodeDB) { found.insert(.openCode) }
        if fm.fileExists(atPath: geminiHistory) { found.insert(.gemini) }
        return found
    }

    private struct CodexFile {
        var id = ""
        var folder = ""
        var started = Date.distantPast
        var working = false
        /// When it last started or finished.
        var since = Date.distantPast
    }

    private var ledger = AgentLedger()
    private var offsets: [String: UInt64] = [:]
    private var splitters: [String: AppendedLines] = [:]
    private var codex: [String: CodexFile] = [:]
    private var openCode: [AgentSession] = []
    private var openCodeNewest: Int64 = 0
    /// Agents whose whole week has been read.
    private var loaded: Set<AgentKind> = []

    /// Reads what's new for these agents: the whole week the first time, then
    /// what was appended to each log since.
    func refresh(_ agents: Set<AgentKind>) -> Snapshot {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-Double(AgentLedger.keepDays) * 86400)
        for agent in agents {
            switch agent {
            case .claudeCode: for f in Self.claudeLogs(modifiedAfter: weekAgo) { read(f, .claudeCode, now: now) }
            case .codex: for f in Self.codexLogs(modifiedAfter: weekAgo) { read(f, .codex, now: now) }
            case .openCode: readOpenCode(now: now)
            case .gemini: read(Self.geminiHistory, .gemini, now: now)
            }
            loaded.insert(agent)
        }
        ledger.prune(now: now)
        return snapshot(now: now)
    }

    /// Files that changed: what was appended to those of agents already read.
    func changed(_ paths: [String], agents: Set<AgentKind>) -> Snapshot {
        let now = Date()
        var openCodeChanged = false
        for path in Set(paths) {
            if path.hasPrefix(Self.claudeProjects), path.hasSuffix(".jsonl") {
                if loaded.contains(.claudeCode), agents.contains(.claudeCode) { read(path, .claudeCode, now: now) }
            } else if path.hasPrefix(Self.codexSessions), path.hasSuffix(".jsonl") {
                if agents.contains(.codex) { read(path, .codex, now: now) }
            } else if path.hasPrefix(Self.openCodeFolder) {
                openCodeChanged = true
            } else if path == Self.geminiHistory, loaded.contains(.gemini), agents.contains(.gemini) {
                read(path, .gemini, now: now)
            }
        }
        if openCodeChanged, agents.contains(.openCode) { readOpenCode(now: now) }
        return snapshot(now: now)
    }

    func current() -> Snapshot { snapshot(now: Date()) }

    private func snapshot(now: Date) -> Snapshot {
        Snapshot(ledger: ledger, sessions: codexSessions(now: now) + openCode)
    }

    // MARK: logs

    /// Reads a log from where it was left; a log that got shorter was rewritten
    /// and is read again (replies already counted are recognised).
    private func read(_ path: String, _ agent: AgentKind, now: Date) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else { return }
        var offset = offsets[path] ?? 0
        if size < offset {
            offset = 0
            splitters[path] = nil
        }
        guard size > offset, let file = FileHandle(forReadingAtPath: path) else { return }
        defer { try? file.close() }
        try? file.seek(toOffset: offset)
        var splitter = splitters[path] ?? AppendedLines()
        while let chunk = try? file.read(upToCount: 4 << 20), !chunk.isEmpty {
            for line in splitter.lines(chunk) { handle(line, agent, path: path, now: now) }
            offset += UInt64(chunk.count)
        }
        offsets[path] = offset
        splitters[path] = splitter
    }

    private func handle(_ line: Data, _ agent: AgentKind, path: String, now: Date) {
        switch agent {
        case .claudeCode:
            if let reply = ClaudeCodeLog.parse(line) { ledger.add(reply, now: now) }
        case .gemini:
            if let reply = GeminiHistory.parse(line) { ledger.add(reply, now: now) }
        case .codex:
            guard let entry = CodexLog.parse(line) else { return }
            var file = codex[path] ?? CodexFile()
            switch entry {
            case .session(let id, let folder, let started):
                file.id = id; file.folder = folder; file.started = started; file.since = started
            case .usage(let time, let tokens, let output, let limit):
                if tokens > 0 {
                    ledger.add(AgentReply(agent: .codex, id: "codex:\(file.id)@\(time.timeIntervalSince1970)", time: time,
                                          tokens: tokens, output: output, session: file.id), now: now)
                }
                if let limit { ledger.limits[.codex] = limit }
            case .started(let time):
                file.working = true; file.since = time
            case .finished(let time):
                file.working = false; file.since = time
            }
            codex[path] = file
        case .openCode:
            break
        }
    }

    /// Codex sessions open now: working (a task started, not finished, written
    /// to lately), or finished within the last half hour, so still to answer.
    private func codexSessions(now: Date) -> [AgentSession] {
        codex.compactMap { path, file in
            guard !file.id.isEmpty else { return nil }
            let written = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? file.since
            let working = file.working && now.timeIntervalSince(written) < 10 * 60
            guard working || now.timeIntervalSince(file.since) < 30 * 60 else { return nil }
            return AgentSession(id: "codex:\(file.id)", agent: .codex, folder: file.folder, state: working ? .working : .waiting,
                                since: file.since, started: file.started,
                                pid: ProcessLookup.pid(named: ["codex"], folder: file.folder))
        }
    }

    // MARK: OpenCode

    /// OpenCode keeps everything in one database: the replies of the week, and
    /// its sessions (working while a reply hasn't completed).
    private func readOpenCode(now: Date) {
        var db: OpaquePointer?
        let uri = "file:\(Self.openCodeDB)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let weekAgo = Int64(now.addingTimeInterval(-Double(AgentLedger.keepDays) * 86400).timeIntervalSince1970 * 1000)
        let from = max(weekAgo, openCodeNewest - 1)
        Self.query(db, "select id, session_id, time_created, data from message where time_created > ? order by time_created", [from]) { row in
            let created = sqlite3_column_int64(row, 2)
            openCodeNewest = max(openCodeNewest, created)
            guard let id = Self.text(row, 0), let data = Self.text(row, 3).map({ Data($0.utf8) }),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], d["role"] as? String == "assistant",
                  let t = d["tokens"] as? [String: Any] else { return }
            let cache = t["cache"] as? [String: Any] ?? [:]
            func n(_ v: Any?) -> Int { v as? Int ?? 0 }
            let output = n(t["output"]) + n(t["reasoning"])
            ledger.add(AgentReply(agent: .openCode, id: "opencode:\(id)", time: Date(timeIntervalSince1970: Double(created) / 1000),
                                  tokens: n(t["input"]) + output + n(cache["read"]) + n(cache["write"]), output: output,
                                  session: Self.text(row, 1) ?? ""), now: now)
        }
        // Sessions touched in the last half hour, and whether their last reply is still being written.
        let recent = Int64(now.addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1000)
        var sessions: [AgentSession] = []
        Self.query(db, "select id, directory, time_created, time_updated from session where time_updated > ? and parent_id is null", [recent]) { row in
            guard let id = Self.text(row, 0) else { return }
            let folder = Self.text(row, 1) ?? ""
            let started = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)) / 1000)
            var since = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1000)
            var working = false
            Self.query(db, "select data, time_created from message where session_id = ? order by time_created desc limit 1", [], text: id) { m in
                guard let data = Self.text(m, 0).map({ Data($0.utf8) }),
                      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let time = d["time"] as? [String: Any] ?? [:]
                let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(m, 1)) / 1000)
                working = d["role"] as? String == "assistant" && time["completed"] == nil && now.timeIntervalSince(created) < 10 * 60
                if working { since = created }
            }
            sessions.append(AgentSession(id: "openCode:\(id)", agent: .openCode, folder: folder, state: working ? .working : .waiting,
                                         since: since, started: started, pid: ProcessLookup.pid(named: ["opencode"], folder: folder)))
        }
        openCode = sessions
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ ints: [Int64], text: String? = nil, _ row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (i, v) in ints.enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), v) }
        if let text {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, Int32(ints.count + 1), text, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    // MARK: finding the logs

    /// Claude Code's logs: one per session in each project's folder, and its
    /// subagents' beside them.
    nonisolated static func claudeLogs(modifiedAfter date: Date) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for project in (try? fm.contentsOfDirectory(atPath: claudeProjects)) ?? [] {
            let dir = claudeProjects + "/" + project
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if name.hasSuffix(".jsonl") {
                    if modified(path) > date { out.append(path) }
                } else if !name.contains(".") {
                    let sub = path + "/subagents"
                    for agent in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where agent.hasSuffix(".jsonl") {
                        if modified(sub + "/" + agent) > date { out.append(sub + "/" + agent) }
                    }
                }
            }
        }
        return out
    }

    /// Codex's logs: ~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl.
    nonisolated static func codexLogs(modifiedAfter date: Date) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: codexSessions) else { return [] }
        var out: [String] = []
        while let name = e.nextObject() as? String {
            let path = codexSessions + "/" + name
            if name.hasSuffix(".jsonl"), modified(path) > date { out.append(path) }
        }
        return out
    }

    nonisolated private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// Running processes, for an agent's session: its process, and the app or
/// terminal it runs in.
nonisolated enum ProcessLookup {
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// A process with one of these names working in this folder.
    static func pid(named names: Set<String>, folder: String) -> Int32? {
        guard !folder.isEmpty else { return nil }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  names.contains(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { continue }
            var vnode = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { continue }
            let cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if cwd == folder { return pid }
        }
        return nil
    }
}
