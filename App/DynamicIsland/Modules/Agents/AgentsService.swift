import AppKit
import IslandCore
import Observation

/// AI coding agents (Settings › AI Agents). Which sessions are open and
/// working comes from the small status files the agents keep, watched while
/// the module is on; the week's usage comes from their logs, read in the
/// background only while something shows it (`acquire`/`release`). Only
/// counts, times and folders are read, never what was said.
@Observable
final class AgentsService: ActivityProvider {
    let kind: ActivityKind = .agents
    /// Sessions open now, working first, of the agents switched on.
    private(set) var sessions: [AgentSession] = []
    /// The last week's usage. Filled the first time something shows it.
    private(set) var ledger = AgentLedger()
    /// Agents found on this Mac.
    private(set) var installed: Set<AgentKind> = []
    /// Reading the week for the first time.
    private(set) var loading = false
    private(set) var loaded = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let reader = AgentLogReader()
    @ObservationIgnored private var liveWatcher: FolderWatcher?
    @ObservationIgnored private var usageWatcher: FolderWatcher?
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var claude: [AgentSession] = []
    @ObservationIgnored private var others: [AgentSession] = []
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var sweep: Task<Void, Never>?

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        engine.register(self)
    }

    var activities: [Activity] {
        let s = settings.settings.agents
        guard s.showWorking else { return [] }
        let working = sessions.filter { $0.state == .working }.sorted { $0.since < $1.since }
        guard let first = working.first else { return [] }
        return [Activity(id: "agents", kind: .agents, payload: .agents(working), relevance: 0.5, startedAt: first.since)]
    }

    /// The agents to show: switched on, and on this Mac.
    var shown: Set<AgentKind> {
        let s = settings.settings.agents
        return installed.filter { s.isOn($0) }
    }

    func start() {
        whenChanged({ [settings] in
            let s = settings.settings
            return "\(s[module: .agents].enabled) \(AgentKind.allCases.map { s.agents.isOn($0) })"
        }) { [weak self] _ in self?.update() }
        update()
    }

    private var enabled: Bool { settings.settings[module: .agents].enabled }

    private func update() {
        installed = AgentLogReader.installed()
        if enabled {
            startLive()
        } else {
            liveWatcher = nil
            usageWatcher = nil
            sweep?.cancel()
            sweep = nil
            claude = []
            others = []
            sessions = []
            return
        }
        if demand > 0 { startUsage() }
        reloadClaude()
        readNow(Array(shown))
    }

    // MARK: open sessions

    /// Claude Code's status files, Codex's logs and OpenCode's database: what's
    /// open and working. Small files, read when they change.
    private func startLive() {
        guard liveWatcher == nil else { return }
        liveWatcher = FolderWatcher(paths: [AgentLogReader.claudeSessions, AgentLogReader.codexSessions, AgentLogReader.openCodeFolder]) { [weak self] paths in
            self?.changed(paths)
        }
        // A session whose app quit without tidying up, or one that went quiet: checked now and then.
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !self.sessions.isEmpty else { continue }
                self.reloadClaude()
                self.readNow([])
            }
        }
    }

    private func changed(_ paths: [String]) {
        if paths.contains(where: { $0.hasPrefix(AgentLogReader.claudeSessions) }) { reloadClaude() }
        let rest = paths.filter { !$0.hasPrefix(AgentLogReader.claudeSessions) }
        guard !rest.isEmpty else { return }
        pending.formUnion(rest)
        // Logs grow a line at a time while an agent works. Codex's and OpenCode's
        // say whether they're working, so they're read within a second; the
        // others only add to the usage, which can wait a few seconds.
        guard readTask == nil else { return }
        let usageOnly = rest.allSatisfy { $0.hasPrefix(AgentLogReader.claudeProjects) || $0 == AgentLogReader.geminiHistory }
        readTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(usageOnly ? 5 : 1))
            guard let self else { return }
            let paths = Array(self.pending)
            self.pending = []
            let snapshot = await self.reader.changed(paths, agents: self.shown)
            self.readTask = nil
            self.apply(snapshot)
        }
    }

    private func reloadClaude() {
        guard shown.contains(.claudeCode) else { claude = []; publish(); return }
        let dir = AgentLogReader.claudeSessions
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        claude = names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let session = ClaudeSessionFile.parse(data), let pid = session.pid, ProcessLookup.isAlive(pid) else { return nil }
            return session
        }
        publish()
    }

    private func readNow(_ agents: [AgentKind]) {
        Task { [weak self] in
            guard let self else { return }
            let snapshot = agents.isEmpty ? await self.reader.current() : await self.reader.refresh(Set(agents).intersection([.codex, .openCode]))
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: AgentLogReader.Snapshot) {
        if snapshot.ledger != ledger { ledger = snapshot.ledger }
        others = snapshot.sessions
        publish()
    }

    private func publish() {
        let on = shown
        let new = (claude + others).filter { on.contains($0.agent) }.sorted {
            $0.state != $1.state ? $0.state == .working : $0.since > $1.since
        }
        guard new != sessions else { return }
        let finished = AgentFinish.between(sessions, new, now: .now)
        sessions = new
        let s = settings.settings.agents
        guard s.alertWhenDone else { return }
        for f in finished where f.duration >= s.alertMinimumSeconds { confirm(f) }
    }

    /// A session can pause between steps: the alert comes only if it's still
    /// waiting for you a moment later.
    private func confirm(_ finish: AgentFinish) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessions.first(where: { $0.id == finish.session })?.state == .waiting else { return }
            self.engine.post(IslandAlert(kind: .agents, style: .agentFinished(finish), holdSeconds: 5))
        }
    }

    // MARK: usage

    /// The dashboard's card or Settings is showing usage: read the week (the
    /// first time) and follow the logs until nothing shows it.
    func acquire() {
        demand += 1
        guard demand == 1, enabled else { return }
        startUsage()
        let agents = shown
        if !loaded { loading = true }
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let snapshot = await self.reader.refresh(agents)
            if !self.loaded { Log.info("agents: read the week in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
            self.loading = false
            self.loaded = true
            self.apply(snapshot)
        }
    }

    func release() {
        demand = max(0, demand - 1)
        guard demand == 0 else { return }
        usageWatcher = nil
    }

    private func startUsage() {
        guard usageWatcher == nil else { return }
        usageWatcher = FolderWatcher(paths: [AgentLogReader.claudeProjects, AgentLogReader.geminiHistory], latency: 1) { [weak self] paths in
            self?.changed(paths)
        }
    }

    // MARK: actions

    /// Brings the app or terminal a session runs in forward.
    func bringForward(_ session: AgentSession) {
        var pid = session.pid
        while let p = pid, p > 1 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                app.activate()
                return
            }
            pid = ProcessLookup.parent(of: p)
        }
    }
}
