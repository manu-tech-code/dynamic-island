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

    /// What's on this Mac, looked for now and then.
    struct Found: Equatable, Sendable {
        var folders: AgentFolders
        var installed: Set<AgentKind>
        /// The folders to watch that exist: one appearing means watching again.
        var watchable: [String]
    }

    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The agents on this Mac and where their files are, with these variables (see `LoginShell`).
    nonisolated static func find(_ environment: [String: String]) -> Found {
        let folders = AgentFolders(home: home, environment: environment, resolve: realPath)
        let watchable = (livePaths(folders) + usagePaths(folders)).filter { FileManager.default.fileExists(atPath: $0) }
        return Found(folders: folders, installed: installed(folders), watchable: watchable)
    }

    /// Which agents are on this Mac: the files they keep exist.
    nonisolated static func installed(_ f: AgentFolders) -> Set<AgentKind> {
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
        var found: Set<AgentKind> = []
        if (f.claudeProjects + f.claudeSessions).contains(where: exists) { found.insert(.claudeCode) }
        if f.codexSessions.contains(where: exists) { found.insert(.codex) }
        if !openCodeDatabases(f).isEmpty || exists(f.openCode + "/storage/message") { found.insert(.openCode) }
        if exists(f.geminiProjects) || exists(f.antigravityHistory) { found.insert(.gemini) }
        return found
    }

    /// Claude Code's status files, Codex's logs and OpenCode's data: what's open and working.
    nonisolated static func livePaths(_ f: AgentFolders) -> [String] {
        f.claudeSessions + [f.codex + "/sessions", f.openCode]
    }

    /// The logs that only add to the usage.
    nonisolated static func usagePaths(_ f: AgentFolders) -> [String] {
        f.claudeProjects + [f.geminiProjects, (f.antigravityHistory as NSString).deletingLastPathComponent]
    }

    /// Whether Claude Code is signed in to a Claude plan (its settings file has
    /// an account), and when that file was last changed, so it's read again only then.
    nonisolated static func claudeSubscription(_ f: AgentFolders, last: (stamp: [Date], value: Bool)?) -> (stamp: [Date], value: Bool) {
        let stamp = f.claudeAccounts.map { modified($0) }
        if let last, last.stamp == stamp { return last }
        let value = f.claudeAccounts.contains { path in
            // A long file (it keeps every project's settings): parsed only when it has an account.
            guard let data = FileManager.default.contents(atPath: path), data.range(of: Data(#""oauthAccount""#.utf8)) != nil,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return d["oauthAccount"] is [String: Any]
        }
        return (stamp, value)
    }

    /// Where a reading left off in a log: the file (logs can be rewritten as new files) and how far.
    private struct Mark {
        var inode: UInt64
        var offset: UInt64
    }

    /// A file read whole, and read again when it changes.
    private struct Stamp: Equatable {
        var inode: UInt64
        var size: UInt64
        var modified: Date
    }

    private struct CodexFile {
        var id = ""
        var folder = ""
        var model = ""
        var started = Date.distantPast
        var working = false
        var interrupted = false
        /// When it last started or finished.
        var since = Date.distantPast
        /// The session's tokens so far, as last reported.
        var total: CodexLog.Tokens?
    }

    private var folders: AgentFolders?
    private var ledger = AgentLedger()
    private var marks: [String: Mark] = [:]
    private var splitters: [String: AppendedLines] = [:]
    private var stamps: [String: Stamp] = [:]
    private var codex: [String: CodexFile] = [:]
    /// Gemini CLI's chats: each one's session.
    private var geminiSessions: [String: String] = [:]
    private var openCode: [AgentSession] = []
    private var openCodeNewest: [String: Int64] = [:]
    /// Agents whose whole week has been read.
    private var loaded: Set<AgentKind> = []
    /// Which agents' processes work in which folders, looked up at most every 20 seconds.
    private var processes: (pids: [String: Int32], checked: Date)?

    /// Reads what's new for these agents: the whole week the first time, then
    /// what was appended to each log since.
    func refresh(_ agents: Set<AgentKind>, in folders: AgentFolders) -> Snapshot {
        use(folders)
        let now = Date()
        let weekAgo = now.addingTimeInterval(-Double(AgentLedger.keepDays) * 86400)
        for agent in agents {
            switch agent {
            case .claudeCode:
                for f in folders.claudeProjects.flatMap({ Self.files(in: $0, [".jsonl"], modifiedAfter: weekAgo) }) { readClaude(f, now: now) }
            case .codex:
                for f in folders.codexSessions.flatMap({ Self.files(in: $0, [".jsonl"], modifiedAfter: weekAgo) }) { readCodex(f, now: now) }
            case .openCode:
                readOpenCode(folders, now: now)
                for f in Self.files(in: folders.openCode + "/storage/message", [".json"], modifiedAfter: weekAgo) { readOpenCodeMessage(f, now: now) }
            case .gemini:
                readAntigravity(folders.antigravityHistory, now: now)
                for f in Self.geminiChats(folders, modifiedAfter: weekAgo) { readGemini(f, now: now) }
            }
            loaded.insert(agent)
        }
        ledger.prune(now: now)
        return snapshot(now: now)
    }

    /// Files that changed: what was appended to those of agents already read.
    func changed(_ paths: [String], agents: Set<AgentKind>, in folders: AgentFolders) -> Snapshot {
        use(folders)
        let now = Date()
        var databaseChanged = false
        for path in Set(paths) {
            switch folders.role(of: path) {
            case .claudeLog:
                if loaded.contains(.claudeCode), agents.contains(.claudeCode) { readClaude(path, now: now) }
            case .codexLog:
                if agents.contains(.codex) { readCodex(path, now: now) }
            case .openCodeData:
                guard agents.contains(.openCode) else { continue }
                if path.hasSuffix(".json") { readOpenCodeMessage(path, now: now) } else { databaseChanged = true }
            case .geminiChat:
                if loaded.contains(.gemini), agents.contains(.gemini) { readGemini(path, now: now) }
            case .antigravityHistory:
                if loaded.contains(.gemini), agents.contains(.gemini) { readAntigravity(path, now: now) }
            case .claudeStatus, nil:
                break
            }
        }
        if databaseChanged { readOpenCode(folders, now: now) }
        return snapshot(now: now)
    }

    /// The sessions as they are now: Codex's from what was read, OpenCode's
    /// asked again (one can go quiet without writing anything).
    func current() -> Snapshot {
        let now = Date()
        if let folders, !openCode.isEmpty { readOpenCode(folders, now: now) }
        return snapshot(now: now)
    }

    /// Starts over when the agents' folders moved.
    private func use(_ folders: AgentFolders) {
        guard folders != self.folders else { return }
        if self.folders != nil {
            ledger = AgentLedger()
            marks = [:]; splitters = [:]; stamps = [:]; codex = [:]; geminiSessions = [:]
            openCode = []; openCodeNewest = [:]; loaded = []
        }
        self.folders = folders
    }

    private func snapshot(now: Date) -> Snapshot {
        Snapshot(ledger: ledger, sessions: codexSessions(now: now) + openCode)
    }

    // MARK: logs

    /// Reads a log from where it was left. One that got shorter, or was
    /// replaced by another file, was rewritten and is read again (replies
    /// already counted are recognised).
    private func read(_ path: String, _ handle: (Data) -> Void) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var mark = marks[path] ?? Mark(inode: inode, offset: 0)
        if size < mark.offset || inode != mark.inode {
            mark = Mark(inode: inode, offset: 0)
            splitters[path] = nil
            codex[path] = nil
            geminiSessions[path] = nil
        }
        guard size > mark.offset, let file = FileHandle(forReadingAtPath: path) else { return }
        defer { try? file.close() }
        try? file.seek(toOffset: mark.offset)
        var splitter = splitters[path] ?? AppendedLines()
        while let chunk = try? file.read(upToCount: 4 << 20), !chunk.isEmpty {
            for line in splitter.lines(chunk) { handle(line) }
            mark.offset += UInt64(chunk.count)
        }
        marks[path] = mark
        splitters[path] = splitter
    }

    /// Whether a file read whole changed since it was last read.
    private func isNew(_ path: String) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let stamp = Stamp(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                          modified: a[.modificationDate] as? Date ?? .distantPast)
        guard stamps[path] != stamp else { return false }
        stamps[path] = stamp
        return true
    }

    private func readClaude(_ path: String, now: Date) {
        read(path) { line in
            if let reply = ClaudeCodeLog.parse(line) { ledger.add(reply, now: now) }
        }
    }

    private func readAntigravity(_ path: String, now: Date) {
        read(path) { line in
            if let prompt = GeminiHistory.parse(line) { ledger.add(prompt, now: now) }
        }
    }

    private func readGemini(_ path: String, now: Date) {
        guard path.hasSuffix(".jsonl") else {
            // Older versions wrote the whole chat again each time.
            guard isNew(path), let data = FileManager.default.contents(atPath: path) else { return }
            for reply in GeminiChat.parseChat(data) { ledger.add(reply, now: now) }
            return
        }
        read(path) { line in
            switch GeminiChat.parse(line) {
            case .session(let id)?:
                geminiSessions[path] = id
            case .reply(var reply)?:
                reply.session = geminiSessions[path] ?? ""
                ledger.add(reply, now: now)
            case nil:
                break
            }
        }
    }

    private func readCodex(_ path: String, now: Date) {
        read(path) { line in
            guard let entry = CodexLog.parse(line) else { return }
            var file = codex[path] ?? CodexFile()
            switch entry {
            case .session(let id, let folder, let started):
                file.id = id; file.folder = folder; file.started = started; file.since = started
            case .model(let model):
                file.model = model
            case .usage(let time, let last, let total, let limits):
                if let t = CodexLog.added(last: last, total: total, previous: file.total), t.input + t.output > 0 {
                    ledger.add(AgentReply(agent: .codex, id: "codex:\(file.id)@\(time.timeIntervalSince1970)", time: time,
                                          tokens: t.input + t.output, output: t.output, session: file.id,
                                          cost: AgentPricing.openAI(model: file.model, input: t.input, cached: t.cached, output: t.output)), now: now)
                }
                if let total { file.total = total }
                if let limits { ledger.note(limits, for: .codex) }
            case .started(let time):
                file.working = true; file.interrupted = false; file.since = time
            case .finished(let time):
                file.working = false; file.interrupted = false; file.since = time
            case .aborted(let time):
                file.working = false; file.interrupted = true; file.since = time
            }
            codex[path] = file
        }
    }

    /// Codex sessions open now: working (a task started, not finished, written
    /// to lately), or finished within the last half hour, so still to answer.
    /// One that went quiet for 10 minutes waits, from the same moment, so it
    /// doesn't count as finished.
    private func codexSessions(now: Date) -> [AgentSession] {
        guard let folders else { return [] }
        let live = folders.codex + "/sessions/"
        var out: [String: AgentSession] = [:]
        for (path, file) in codex where !file.id.isEmpty && path.hasPrefix(live) {
            guard file.working || now.timeIntervalSince(file.since) < 30 * 60,
                  let written = Self.modifiedIfThere(path) else { continue }
            let working = file.working && now.timeIntervalSince(written) < 10 * 60
            guard working || now.timeIntervalSince(file.since) < 30 * 60 else { continue }
            let session = AgentSession(id: "codex:\(file.id)", agent: .codex, folder: file.folder, state: working ? .working : .waiting,
                                       since: file.since, started: file.started, pid: pid(["codex"], file.folder, now: now),
                                       interrupted: file.interrupted)
            if let other = out[session.id], other.since >= session.since { continue }
            out[session.id] = session
        }
        return Array(out.values)
    }

    private func pid(_ names: Set<String>, _ folder: String, now: Date) -> Int32? {
        guard !folder.isEmpty else { return nil }
        if processes == nil || now.timeIntervalSince(processes!.checked) > 20 {
            processes = (ProcessLookup.workingFolders(named: ["codex", "opencode", "opencode-cli"]), now)
        }
        let resolved = Self.realPath(folder)
        for name in names {
            if let pid = processes?.pids[ProcessLookup.key(name, resolved)] { return pid }
        }
        return nil
    }

    // MARK: OpenCode

    /// OpenCode keeps everything in one database (a preview has its own):
    /// the replies of the week, and its sessions.
    private func readOpenCode(_ folders: AgentFolders, now: Date) {
        openCode = Self.openCodeDatabases(folders).flatMap { readOpenCodeDatabase($0, now: now) }
    }

    private func readOpenCodeDatabase(_ path: String, now: Date) -> [AgentSession] {
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let weekAgo = Int64(now.addingTimeInterval(-Double(AgentLedger.keepDays) * 86400).timeIntervalSince1970 * 1000)
        // By when they were last written: a reply is counted once it's completed, which comes after it's created.
        var newest = openCodeNewest[path] ?? 0
        Self.query(db, "select id, session_id, time_created, time_updated, data from message where time_updated > ? order by time_updated",
                   [max(weekAgo, newest - 1)]) { row in
            newest = max(newest, sqlite3_column_int64(row, 3))
            guard let id = Self.text(row, 0), let data = Self.text(row, 4).map({ Data($0.utf8) }),
                  let reply = OpenCodeMessage.reply(data, id: "opencode:\(id)", session: Self.text(row, 1) ?? "",
                                                    created: Self.date(sqlite3_column_int64(row, 2))) else { return }
            ledger.add(reply, now: now)
        }
        openCodeNewest[path] = newest
        // Sessions touched in the last half hour, and what their last message says.
        let recent = Int64(now.addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1000)
        var sessions: [AgentSession] = []
        Self.query(db, "select id, directory, time_created, time_updated from session where time_updated > ? and parent_id is null", [recent]) { row in
            guard let id = Self.text(row, 0) else { return }
            let folder = Self.text(row, 1) ?? ""
            var asked: Date?
            Self.query(db, "select time_created from message where session_id = ? and json_extract(data, '$.role') = 'user' order by time_created desc limit 1",
                       [], text: id) { m in asked = Self.date(sqlite3_column_int64(m, 0)) }
            var activity = OpenCodeMessage.Activity(state: .waiting, since: Self.date(sqlite3_column_int64(row, 3)))
            Self.query(db, "select data, time_created, time_updated from message where session_id = ? order by time_created desc limit 1", [], text: id) { m in
                guard let data = Self.text(m, 0).map({ Data($0.utf8) }),
                      let a = OpenCodeMessage.activity(data, created: Self.date(sqlite3_column_int64(m, 1)),
                                                       written: Self.date(sqlite3_column_int64(m, 2)), asked: asked, now: now) else { return }
                activity = a
            }
            sessions.append(AgentSession(id: "openCode:\(id)", agent: .openCode, folder: folder, state: activity.state, since: activity.since,
                                         started: Self.date(sqlite3_column_int64(row, 2)), pid: pid(["opencode", "opencode-cli"], folder, now: now),
                                         interrupted: activity.interrupted))
        }
        return sessions
    }

    /// A message from before version 1.2, when each one was a JSON file.
    private func readOpenCodeMessage(_ path: String, now: Date) {
        guard isNew(path), let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = d["id"] as? String,
              let reply = OpenCodeMessage.reply(data, id: "opencode:\(id)", session: d["sessionID"] as? String ?? "",
                                                created: stamps[path]?.modified ?? now) else { return }
        ledger.add(reply, now: now)
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

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

    /// OpenCode's databases: opencode.db, and a preview's opencode-<channel>.db.
    nonisolated static func openCodeDatabases(_ f: AgentFolders) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.openCode)) ?? [])
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .map { f.openCode + "/" + $0 }
    }

    /// Gemini CLI's chats: tmp/<project>/chats/, its subagents' in folders inside.
    nonisolated static func geminiChats(_ f: AgentFolders, modifiedAfter date: Date) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.geminiProjects)) ?? []).flatMap {
            files(in: f.geminiProjects + "/" + $0 + "/chats", [".jsonl", ".json"], modifiedAfter: date)
        }
    }

    /// Files with these endings anywhere inside a folder, changed since a date.
    /// Claude Code's subagents' logs, for one, can be several folders deep.
    nonisolated static func files(in folder: String, _ endings: [String], modifiedAfter date: Date) -> [String] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true),
                                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [String] = []
        while let url = e.nextObject() as? URL {
            let name = url.lastPathComponent
            guard endings.contains(where: { name.hasSuffix($0) }),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > date else { continue }
            out.append(url.path)
        }
        return out
    }

    nonisolated private static func modified(_ path: String) -> Date {
        modifiedIfThere(path) ?? .distantPast
    }

    nonisolated private static func modifiedIfThere(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// The path with symlinks resolved, as file-change events give it; as it is when it isn't there.
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The variables that move the agents' folders, as your login shell sets them:
/// an app opened from the Dock doesn't see what your shell profile exports.
nonisolated enum LoginShell {
    /// Runs your shell as at login and keeps these variables from what it
    /// prints; nothing if it fails or takes longer than `timeout`.
    static func variables(_ names: [String], timeout: TimeInterval = 3) -> [String: String] {
        guard let user = getpwuid(getuid()), let field = user.pointee.pw_shell else { return [:] }
        let shell = String(cString: field)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/env"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        // Read until it's done or the time's up: something it starts can keep the pipe open.
        let fd = out.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(left * 1000)) > 0 else { break }
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        if process.isRunning { process.terminate() }
        var found: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            if names.contains(name) { found[name] = String(line[line.index(after: eq)...]) }
        }
        return found
    }
}

/// Running processes, for an agent's session: its process, and the app or
/// terminal it runs in.
nonisolated enum ProcessLookup {
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static func parent(of pid: Int32) -> Int32? {
        guard let ppid = info(pid)?.kp_eproc.e_ppid, ppid > 0 else { return nil }
        return ppid
    }

    /// When a process started; nil if it isn't running.
    static func startTime(of pid: Int32) -> Date? {
        guard let t = info(pid)?.kp_proc.p_un.__p_starttime else { return nil }
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    static func key(_ name: String, _ folder: String) -> String { name + "\u{0}" + folder }

    /// The processes with these names and the folders they work in (symlinks
    /// resolved), by `key(name, folder)`.
    static func workingFolders(named names: Set<String>) -> [String: Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var out: [String: Int32] = [:]
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let process = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard names.contains(process) else { continue }
            var vnode = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { continue }
            let cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            out[key(process, AgentLogReader.realPath(cwd))] = pid
        }
        return out
    }
}
