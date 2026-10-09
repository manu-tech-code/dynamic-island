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
    /// Sessions open now, of the agents switched on: the ones that need you first, then working.
    private(set) var sessions: [AgentSession] = []
    /// The last week's usage. Filled the first time something shows it.
    private(set) var ledger = AgentLedger()
    /// Agents found on this Mac.
    private(set) var installed: Set<AgentKind> = []
    /// Where they keep their files.
    private(set) var folders = AgentFolders(home: AgentLogReader.home)
    /// Claude Code is signed in to a Claude plan, which counts usage in 5-hour
    /// windows (with an API key there's no window).
    private(set) var claudeSubscription = false
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
    @ObservationIgnored private var askedShell = false
    /// The variables that move the agents' folders: this app's, then your login shell's.
    @ObservationIgnored private var environment = ProcessInfo.processInfo.environment.filter { AgentFolders.variables.contains($0.key) }
    /// The watched folders that exist, to notice one appearing.
    @ObservationIgnored private var watched: [String] = []
    @ObservationIgnored private var account: (stamp: [Date], value: Bool)?

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

    /// An app opened from the Dock doesn't see what your shell profile exports,
    /// which can move the agents' folders: asked of your shell once, when agents are on.
    private func askShell() {
        guard !askedShell else { return }
        askedShell = true
        Task { [weak self] in
            let shell = await Task.detached { LoginShell.variables(AgentFolders.variables) }.value
            guard let self, !shell.isEmpty else { return }
            self.environment.merge(shell) { $1 }
            self.detect()
        }
    }

    private var enabled: Bool { settings.settings[module: .agents].enabled }

    private func update() {
        sweep?.cancel()
        sweep = nil
        guard enabled else {
            detect()
            liveWatcher = nil
            usageWatcher = nil
            claude = []
            others = []
            sessions = []
            return
        }
        detect(restart: true)
        askShell()
        // Now and then: a session whose app quit without tidying up, or one that
        // went quiet; and, each minute, agents installed since.
        sweep = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                if !self.sessions.isEmpty {
                    self.reloadClaude()
                    self.readCurrent()
                }
                if tick % 2 == 0 { self.detect() }
            }
        }
    }

    /// Finds the agents on this Mac and where they keep their files, and
    /// watches again when that changed: one installed since, or a folder that
    /// appeared or moved.
    private func detect(restart: Bool = false) {
        let found = AgentLogReader.find(environment)
        let changed = found.folders != folders || found.installed != installed || found.watchable != watched
        if found.folders != folders { folders = found.folders }
        if found.installed != installed { installed = found.installed }
        watched = found.watchable
        checkAccount()
        guard enabled, restart || changed else { return }
        if !restart { Log.info("agents: watching again, found \(installed.map(\.rawValue).sorted())") }
        liveWatcher = nil
        usageWatcher = nil
        startLive()
        if demand > 0 { startUsage() }
        reloadClaude()
        readNow(all: demand > 0)
    }

    /// Whether Claude Code is signed in to a plan, read from its settings when they change.
    private func checkAccount() {
        let folders = folders, last = account
        Task { [weak self] in
            let result = await Task.detached { AgentLogReader.claudeSubscription(folders, last: last) }.value
            guard let self else { return }
            self.account = result
            if self.claudeSubscription != result.value { self.claudeSubscription = result.value }
        }
    }

    // MARK: open sessions

    /// Claude Code's status files, Codex's logs and OpenCode's database: what's
    /// open and working. Small files, read when they change.
    private func startLive() {
        guard liveWatcher == nil else { return }
        liveWatcher = FolderWatcher(paths: AgentLogReader.livePaths(folders)) { [weak self] paths in
            self?.changed(paths)
        }
    }

    private func changed(_ paths: [String]) {
        let roles = paths.compactMap { path in folders.role(of: path).map { (path, $0) } }
        if roles.contains(where: { $0.1 == .claudeStatus }) { reloadClaude() }
        let rest = roles.filter { $0.1 != .claudeStatus }
        guard !rest.isEmpty else { return }
        pending.formUnion(rest.map(\.0))
        // Logs grow a line at a time while an agent works. Codex's and OpenCode's
        // say whether they're working, so they're read within a second; the
        // others only add to the usage, which can wait a few seconds.
        guard readTask == nil else { return }
        let usageOnly = rest.allSatisfy { $0.1 == .claudeLog || $0.1 == .geminiChat || $0.1 == .antigravityHistory }
        readTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(usageOnly ? 5 : 1))
            guard let self else { return }
            let paths = Array(self.pending)
            self.pending = []
            let snapshot = await self.reader.changed(paths, agents: self.shown, in: self.folders)
            self.readTask = nil
            self.apply(snapshot)
        }
    }

    /// Claude Code's sessions: a status file each, while its process runs. A
    /// file left behind by a process that quit, whose number another process
    /// now has, is told apart by when that process started.
    private func reloadClaude() {
        guard shown.contains(.claudeCode) else { claude = []; publish(); return }
        var found: [String: AgentSession] = [:]
        for dir in folders.claudeSessions {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
                guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                      let parsed = ClaudeSessionFile.parse(data), let pid = parsed.session.pid, ProcessLookup.isAlive(pid),
                      ClaudeSessionFile.isSameProcess(written: parsed.processStart, running: ProcessLookup.startTime(of: pid),
                                                      fileWritten: parsed.session.since) else { continue }
                found[parsed.session.id] = parsed.session
            }
        }
        claude = Array(found.values)
        publish()
    }

    /// Reads the open sessions (Codex's logs, OpenCode's database), or all the
    /// usage when something shows it.
    private func readNow(all: Bool) {
        let agents = all ? shown : shown.intersection([.codex, .openCode])
        let folders = folders
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.reader.refresh(agents, in: folders)
            self.apply(snapshot)
        }
    }

    /// The sessions as last read, checked again (one that went quiet stops working).
    private func readCurrent() {
        Task { [weak self] in
            guard let self else { return }
            self.apply(await self.reader.current())
        }
    }

    private func apply(_ snapshot: AgentLogReader.Snapshot) {
        // Compares the numbers, not the week's replies counted (see AgentLedger's ==).
        if snapshot.ledger != ledger { ledger = snapshot.ledger }
        others = snapshot.sessions
        publish()
    }

    private func publish() {
        let on = shown
        let order: [AgentState: Int] = [.needsYou: 0, .working: 1, .waiting: 2]
        let new = (claude + others).filter { on.contains($0.agent) }.sorted {
            $0.state != $1.state ? order[$0.state, default: 2] < order[$1.state, default: 2] : $0.since > $1.since
        }
        guard new != sessions else { return }
        let stopped = AgentFinish.between(sessions, new)
        sessions = new
        let s = settings.settings.agents
        guard s.alertWhenDone else { return }
        for f in stopped where f.duration >= s.alertMinimumSeconds { confirm(f) }
    }

    /// A session can pause between steps: the alert comes only if it's still
    /// waiting for you (or still asking) a moment later.
    private func confirm(_ finish: AgentFinish) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessions.first(where: { $0.id == finish.session })?.state == (finish.needsYou ? .needsYou : .waiting) else { return }
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
        let agents = shown, folders = folders
        if !loaded { loading = true }
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let snapshot = await self.reader.refresh(agents, in: folders)
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
        usageWatcher = FolderWatcher(paths: AgentLogReader.usagePaths(folders), latency: 1) { [weak self] paths in
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
        // Codex's and OpenCode's own apps run their sessions away from the project's folder: the app, if it's open.
        let apps: [AgentKind: String] = [.codex: "Codex", .openCode: "OpenCode"]
        if let name = apps[session.agent],
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name && $0.activationPolicy == .regular }) {
            app.activate()
        }
    }
}
