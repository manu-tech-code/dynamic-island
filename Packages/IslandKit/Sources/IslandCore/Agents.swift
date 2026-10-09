import Foundation

/// AI coding agents whose usage the island shows (Settings › AI Agents), read
/// from the files each one keeps on this Mac. Only counts, times and folders
/// are read, never what was said, and nothing is sent anywhere.
public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex, openCode, gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .gemini: "Gemini"
        }
    }

    /// The letters on its badge.
    public var letter: String {
        switch self {
        case .claudeCode: "C"
        case .codex: "Cx"
        case .openCode: "O"
        case .gemini: "G"
        }
    }

    /// Its colour, as 0xRRGGBB.
    public var colorHex: UInt32 {
        switch self {
        case .claudeCode: 0xE8845E
        case .codex: 0x34C79A
        case .openCode: 0x5B8CFF
        case .gemini: 0xB48CFF
        }
    }
}

/// Which card the dashboard's AI Agents widget shows.
public enum AgentCardStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A row per agent: today's activity, a dot while it runs; Claude's window below.
    case agents
    /// Claude Code's 5-hour window as a ring, with the time left.
    case window
    /// Today, hour by hour.
    case today
    /// The sessions open now, working or waiting for you.
    case running

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agents: "All your agents"
        case .window: "Claude Code's 5-hour window"
        case .today: "Today, hour by hour"
        case .running: "What's running now"
        }
    }

    /// The card's own title.
    public var cardTitle: String {
        switch self {
        case .agents: "Agents"
        case .window: "Claude Code"
        case .today: "Agents today"
        case .running: "Running"
        }
    }

    public var summary: String {
        switch self {
        case .agents: "A row per agent with what it did today and a green dot while it's working. Below, Claude Code's 5-hour window and when it resets, with a Claude plan, or Codex's limits."
        case .window: "Claude plans count usage in 5-hour windows. The ring is how far through it you are, with the time left, estimated from your replies; the medium card adds tokens, replies and sessions."
        case .today: "How hard your agents worked each hour today, with today's totals above."
        case .running: "The sessions open now, by project: working, needing you, or waiting for you. Click one to bring its app or terminal forward."
        }
    }
}

public struct AgentSettings: Codable, Equatable, Sendable {
    public var card: AgentCardStyle = .agents
    /// What the work would cost at the provider's API prices, beside the tokens.
    public var showCost = true
    /// Which agents show, by kind. One not chosen yet shows (if it's on this Mac).
    public var agents: [String: Bool] = [:]
    /// While an agent works, the island shows it with a spinner and how long it's been going.
    public var showWorking = true
    /// When an agent stops and waits for you, an alert says which, where and how long it took.
    public var alertWhenDone = true
    /// Only for work that took at least this long.
    public var alertMinimumSeconds: Double = 30
    public static let alertMinimumRange = 0.0...600.0

    public init() {}

    public func isOn(_ agent: AgentKind) -> Bool { agents[agent.rawValue] ?? true }
}

// MARK: sessions

public enum AgentState: String, Equatable, Sendable {
    case working
    /// Stopped to ask you something (`AgentSession.reason` says what) before it goes on.
    case needsYou
    /// Done for now: waiting for you to answer.
    case waiting
}

/// A session open now.
public struct AgentSession: Identifiable, Equatable, Sendable {
    /// "<agent>:<its session id>".
    public var id: String
    public var agent: AgentKind
    /// The folder it works in.
    public var folder: String
    public var state: AgentState
    /// When it started working, or began waiting.
    public var since: Date
    public var started: Date
    /// Its process, to bring its app or terminal forward.
    public var pid: Int32?
    /// What it needs from you, when it says: "approve Bash".
    public var reason: String?
    /// You stopped it (or it was replaced): it waits for you, but didn't finish.
    public var interrupted: Bool

    public init(id: String, agent: AgentKind, folder: String, state: AgentState, since: Date, started: Date, pid: Int32? = nil,
                reason: String? = nil, interrupted: Bool = false) {
        self.id = id; self.agent = agent; self.folder = folder; self.state = state
        self.since = since; self.started = started; self.pid = pid; self.reason = reason; self.interrupted = interrupted
    }

    /// The project: the folder's name, or the repository's for a worktree.
    public var project: String {
        let parts = folder.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i >= 2, parts[i - 1] == ".claude" { return parts[i - 2] }
        return parts.last ?? folder
    }
}

/// A session that stopped working: finished and waiting for you, or asking you something.
public struct AgentFinish: Identifiable, Equatable, Sendable {
    public var id: String
    /// The session's id.
    public var session: String
    public var agent: AgentKind
    public var project: String
    public var duration: TimeInterval
    /// It stopped to ask you something rather than finished.
    public var needsYou: Bool
    /// What it asks for, when it says: "approve Bash".
    public var reason: String?

    public init(id: String, session: String, agent: AgentKind, project: String, duration: TimeInterval, needsYou: Bool = false, reason: String? = nil) {
        self.id = id; self.session = session; self.agent = agent; self.project = project; self.duration = duration
        self.needsYou = needsYou; self.reason = reason
    }

    /// The sessions that were working and now wait for you, done or asking
    /// something. Only a real change counts: one that went quiet, that you
    /// stopped, or that's gone (its app quit) didn't finish.
    public static func between(_ before: [AgentSession], _ after: [AgentSession]) -> [AgentFinish] {
        let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return before.compactMap { old in
            guard old.state == .working, let new = current[old.id], new.state != .working,
                  new.since > old.since, !new.interrupted else { return nil }
            let needsYou = new.state == .needsYou
            return AgentFinish(id: "\(old.id)@\(Int(new.since.timeIntervalSince1970))\(needsYou ? "?" : "")", session: old.id,
                               agent: old.agent, project: old.project, duration: new.since.timeIntervalSince(old.since),
                               needsYou: needsYou, reason: needsYou ? new.reason : nil)
        }
    }
}

/// Claude Code writes a small file per running session (<its folder>/sessions/<pid>.json):
/// its folder, when it and its process started, and whether it's busy, idle,
/// or waiting for you (and for what).
public enum ClaudeSessionFile {
    /// The session, and when its process started (the number of a process
    /// that quit can be given to another one). Nil for background and spare
    /// sessions, and ones from another machine.
    public static func parse(_ data: Data, timeZone: TimeZone = .autoupdatingCurrent) -> (session: AgentSession, processStart: Date?)? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["sessionId"] as? String else { return nil }
        if let kind = d["kind"] as? String, kind != "interactive" { return nil }
        if let spare = d["spare"], !(spare is NSNull), (spare as? Bool) != false { return nil }
        if let domain = d["pidDomain"] as? String, domain != "darwin" { return nil }
        func date(_ key: String) -> Date? { (d[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let started = date("startedAt") ?? date("updatedAt") ?? .distantPast
        let state: AgentState = switch d["status"] as? String {
        case "busy": .working
        case "waiting": .needsYou
        default: .waiting
        }
        let reason = state == .needsYou ? (d["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
        let session = AgentSession(id: "claudeCode:\(id)", agent: .claudeCode, folder: d["cwd"] as? String ?? "", state: state,
                                   since: date("statusUpdatedAt") ?? date("updatedAt") ?? started, started: started,
                                   pid: (d["pid"] as? Int).map { Int32($0) }, reason: reason)
        return (session, (d["procStart"] as? String).flatMap { processStart($0, timeZone: timeZone) })
    }

    /// "Fri Oct  9 07:34:57 2026", the process's start in local time, as `ps` shows it.
    public static func processStart(_ s: String, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.split(separator: " ").joined(separator: " "))
    }

    /// Whether the process running with the file's number is the one that wrote
    /// it: they started in the same second. A file that doesn't say is believed.
    /// After a change of time zone the start written (in local time) is whole
    /// quarter hours off; then it's the same if it was running when the file
    /// was last written, as a process given the number later can't have been.
    public static func isSameProcess(written: Date?, running: Date?, fileWritten: Date? = nil) -> Bool {
        guard let written else { return true }
        guard let running else { return false }
        let gap = running.timeIntervalSince(written)
        if gap > -1 && gap < 2 { return true }
        let zones = (gap / 900).rounded() * 900
        guard let fileWritten, abs(zones) <= 14 * 3600, abs(gap - zones) < 2 else { return false }
        return running <= fileWritten
    }
}

// MARK: usage

/// One reply: when, how many tokens it read and wrote.
public struct AgentReply: Equatable, Sendable {
    public var agent: AgentKind
    /// Counts a reply once: Claude Code logs one reply on several lines.
    public var id: String?
    public var time: Date
    /// Everything read and written, cached input included.
    public var tokens: Int
    /// What it wrote.
    public var output: Int
    public var session: String
    /// What it would cost at the provider's API prices, in US dollars (see
    /// `AgentPricing`), or nil for a model without a public price.
    public var cost: Double?
    /// A prompt you typed rather than a reply: all Antigravity CLI keeps.
    public var prompt: Bool

    public init(agent: AgentKind, id: String?, time: Date, tokens: Int, output: Int, session: String, cost: Double? = 0, prompt: Bool = false) {
        self.agent = agent; self.id = id; self.time = time; self.tokens = tokens; self.output = output
        self.session = session; self.cost = cost; self.prompt = prompt
    }

    /// Its tokens, if its model has no price.
    public var unpriced: Int { cost == nil ? tokens : 0 }
}

/// A plan limit, as Codex reports it.
public struct AgentLimit: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }

    /// The stretch it counts over: "5 h", "week".
    public var name: String? {
        guard let m = windowMinutes, m > 0 else { return nil }
        switch m {
        case 7 * 24 * 60: return "week"
        case 24 * 60: return "day"
        default: return IslandFormat.duration(minutes: m)
        }
    }
}

/// Codex's plan limits at one moment: usually a 5-hour one and a weekly one.
public struct AgentLimits: Equatable, Sendable {
    public var time: Date
    public var primary: AgentLimit?
    public var secondary: AgentLimit?

    public init(time: Date, primary: AgentLimit?, secondary: AgentLimit?) {
        self.time = time; self.primary = primary; self.secondary = secondary
    }

    /// The ones that haven't reset since.
    public func current(now: Date) -> [AgentLimit] {
        [primary, secondary].compactMap { $0 }.filter { ($0.resetsAt ?? .distantFuture) > now }
    }
}

/// A day of one agent's work.
public struct AgentDay: Equatable, Sendable {
    /// Tokens per hour of the day.
    public var hours = [Int](repeating: 0, count: 24)
    public var replies = 0
    /// Prompts you typed, where only those are known (Antigravity CLI).
    public var prompts = 0
    public var output = 0
    public var sessions: Set<String> = []
    /// In US dollars, at API prices.
    public var cost = 0.0
    /// Tokens of models without a price, left out of `cost`.
    public var unpriced = 0

    public init() {}

    public var tokens: Int { hours.reduce(0, +) }
}

/// Some of an agent's work, added up.
public struct AgentTotals: Equatable, Sendable {
    public var tokens = 0
    public var replies = 0
    public var prompts = 0
    public var sessions = 0
    public var cost = 0.0
    /// Tokens of models without a price, left out of `cost`.
    public var unpriced = 0
}

/// Claude's 5-hour window, as estimated from the replies: it opens on the hour
/// (in UTC) of the first reply after the last one closed, and resets five hours later.
public struct AgentWindow: Equatable, Sendable {
    public static let length: TimeInterval = 5 * 3600

    public var start: Date
    public var tokens: Int
    public var cost = 0.0
    /// Tokens of models without a price, left out of `cost`.
    public var unpriced = 0

    public var resets: Date { start.addingTimeInterval(Self.length) }
    public func left(now: Date) -> TimeInterval { max(0, resets.timeIntervalSince(now)) }
    /// How far through it is, 0…1.
    public func fraction(now: Date) -> Double { min(1, max(0, now.timeIntervalSince(start) / Self.length)) }
}

/// The last week of replies, per agent and day, kept as they're read.
public struct AgentLedger: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var id: String?
        public var time: Date
        public var tokens: Int
        public var cost: Double
        public var unpriced: Int
    }

    /// A session's spend over the week.
    struct Spend: Equatable, Sendable {
        var cost = 0.0
        var unpriced = 0
        var last = Date.distantPast
    }

    /// What a reply added, to take it back when a fuller copy of it comes.
    struct Counted: Sendable {
        var agent: AgentKind
        var time: Date
        var tokens: Int
        var output: Int
        var cost: Double
        var unpriced: Int
        var session: String
        var prompt: Bool
    }

    public static let keepDays = 8

    public private(set) var days: [AgentKind: [Date: AgentDay]] = [:]
    /// The last day's replies, for the 5-hour window.
    public private(set) var recent: [AgentKind: [Point]] = [:]
    public private(set) var lastUsed: [AgentKind: Date] = [:]
    /// The newest plan limits each agent reported.
    public private(set) var limits: [AgentKind: AgentLimits] = [:]
    private var seen: [String: Counted] = [:]
    private var spend: [String: Spend] = [:]
    private let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) { self.calendar = calendar }

    /// The same numbers. Which replies were counted, a week of them, isn't compared.
    public static func == (a: AgentLedger, b: AgentLedger) -> Bool {
        a.days == b.days && a.lastUsed == b.lastUsed && a.limits == b.limits && a.spend == b.spend && a.recent == b.recent
    }

    /// Adds a reply; false if it's older than a week or already counted. A
    /// reply seen again with more tokens replaces the first copy: Claude Code
    /// can first write one with only part of its output.
    @discardableResult
    public mutating func add(_ reply: AgentReply, now: Date) -> Bool {
        guard reply.time > now.addingTimeInterval(-Double(Self.keepDays) * 86400) else { return false }
        let counted = Counted(agent: reply.agent, time: reply.time, tokens: reply.tokens, output: reply.output, cost: reply.cost ?? 0,
                              unpriced: reply.unpriced, session: reply.session, prompt: reply.prompt)
        if let id = reply.id {
            if let old = seen[id] {
                guard reply.tokens > old.tokens || (reply.tokens == old.tokens && reply.output > old.output) else { return false }
                take(old, id: id)
            }
            seen[id] = counted
        }
        let day = calendar.startOfDay(for: reply.time)
        let hour = calendar.component(.hour, from: reply.time)
        var d = days[reply.agent]?[day] ?? AgentDay()
        d.hours[hour] += counted.tokens
        if counted.prompt { d.prompts += 1 } else { d.replies += 1 }
        d.output += counted.output
        d.cost += counted.cost
        d.unpriced += counted.unpriced
        if !reply.session.isEmpty {
            d.sessions.insert(reply.session)
            let key = "\(reply.agent.rawValue):\(reply.session)"
            spend[key, default: Spend()].cost += counted.cost
            spend[key]!.unpriced += counted.unpriced
            if reply.time > spend[key]!.last { spend[key]!.last = reply.time }
        }
        days[reply.agent, default: [:]][day] = d
        if reply.time > now.addingTimeInterval(-86400) {
            recent[reply.agent, default: []].append(Point(id: reply.id, time: reply.time, tokens: counted.tokens, cost: counted.cost,
                                                          unpriced: counted.unpriced))
        }
        if reply.time > lastUsed[reply.agent] ?? .distantPast { lastUsed[reply.agent] = reply.time }
        return true
    }

    /// Takes back what a reply added.
    private mutating func take(_ old: Counted, id: String) {
        let day = calendar.startOfDay(for: old.time)
        if var d = days[old.agent]?[day] {
            d.hours[calendar.component(.hour, from: old.time)] -= old.tokens
            if old.prompt { d.prompts -= 1 } else { d.replies -= 1 }
            d.output -= old.output
            d.cost = max(0, d.cost - old.cost)
            d.unpriced -= old.unpriced
            days[old.agent]?[day] = d
        }
        let key = "\(old.agent.rawValue):\(old.session)"
        if !old.session.isEmpty, var s = spend[key] {
            s.cost = max(0, s.cost - old.cost)
            s.unpriced -= old.unpriced
            spend[key] = s
        }
        // Its copies are written one after the other: look from the end.
        if let i = recent[old.agent]?.lastIndex(where: { $0.id == id }) { recent[old.agent]?.remove(at: i) }
    }

    /// Keeps the newest limits an agent reported (its logs aren't read in order).
    public mutating func note(_ new: AgentLimits, for agent: AgentKind) {
        if new.time >= limits[agent]?.time ?? .distantPast { limits[agent] = new }
    }

    /// Forgets what's older than the week, and the last day's points past a day.
    public mutating func prune(now: Date) {
        let cutoff = calendar.startOfDay(for: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        for agent in days.keys { days[agent] = days[agent]?.filter { $0.key >= cutoff } }
        seen = seen.filter { $0.value.time >= cutoff }
        spend = spend.filter { $0.value.last >= cutoff }
        let dayAgo = now.addingTimeInterval(-86400)
        for agent in recent.keys { recent[agent]?.removeAll { $0.time < dayAgo } }
    }

    public func today(_ agent: AgentKind, now: Date) -> AgentDay {
        days[agent]?[calendar.startOfDay(for: now)] ?? AgentDay()
    }

    /// The last seven days, today included.
    public func week(_ agent: AgentKind, now: Date) -> AgentTotals {
        let from = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86400))
        let list = (days[agent] ?? [:]).filter { $0.key >= from }.map(\.value)
        return AgentTotals(tokens: list.reduce(0) { $0 + $1.tokens }, replies: list.reduce(0) { $0 + $1.replies },
                           prompts: list.reduce(0) { $0 + $1.prompts },
                           sessions: list.reduce(into: Set<String>()) { $0.formUnion($1.sessions) }.count,
                           cost: list.reduce(0) { $0 + $1.cost }, unpriced: list.reduce(0) { $0 + $1.unpriced })
    }

    /// What a session has cost over the week, if it replied in it, with the
    /// tokens of models without a price.
    public func cost(of session: AgentSession) -> (cost: Double, unpriced: Int)? {
        spend[session.id].map { ($0.cost, $0.unpriced) }
    }

    /// The window open now, if one is.
    public func window(_ agent: AgentKind = .claudeCode, now: Date) -> AgentWindow? {
        var current: AgentWindow?
        for p in (recent[agent] ?? []).sorted(by: { $0.time < $1.time }) {
            if current == nil || p.time >= current!.resets {
                // On the hour in UTC: in India (+5:30) a window opens at half past.
                let hour = (p.time.timeIntervalSince1970 / 3600).rounded(.down) * 3600
                current = AgentWindow(start: Date(timeIntervalSince1970: hour), tokens: 0)
            }
            current!.tokens += p.tokens
            current!.cost += p.cost
            current!.unpriced += p.unpriced
        }
        guard let current, now < current.resets else { return nil }
        return current
    }

    /// Plan limits that haven't reset yet.
    public func limits(_ agent: AgentKind, now: Date) -> [AgentLimit] {
        limits[agent]?.current(now: now) ?? []
    }
}

// MARK: reading the logs

/// Claude Code's logs (<its folder>/projects/<project>/<session>.jsonl, and its
/// subagents' further in): a line per event; replies carry their token counts.
public enum ClaudeCodeLog {
    /// A reply's usage, or nil for anything else.
    private static let usageKey = Data(#""usage""#.utf8)
    private static let assistantKey = Data(#""type":"assistant""#.utf8)

    public static func parse(_ line: Data) -> AgentReply? {
        guard line.range(of: usageKey) != nil, line.range(of: assistantKey) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant", d["isApiErrorMessage"] as? Bool != true,
              let message = d["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = (d["timestamp"] as? String).flatMap(Self.date) else { return nil }
        // Notes Claude Code writes itself ("<synthetic>"), not replies.
        let model = message["model"] as? String ?? ""
        guard model != "<synthetic>" else { return nil }
        func n(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        let output = n("output_tokens")
        let written = n("cache_creation_input_tokens")
        let tokens = n("input_tokens") + written + n("cache_read_input_tokens") + output
        // Cache writes last 5 minutes or an hour, at different prices; older logs don't say which.
        let split = usage["cache_creation"] as? [String: Any]
        let hour = (split?["ephemeral_1h_input_tokens"] as? Int) ?? 0
        let searches = ((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int) ?? 0
        let cost = AgentPricing.claude(model: model, input: n("input_tokens"), cacheWrite5m: max(0, written - hour), cacheWrite1h: hour,
                                       cacheRead: n("cache_read_input_tokens"), output: output, webSearches: searches,
                                       fast: usage["speed"] as? String == "fast", usOnly: usage["inference_geo"] as? String == "us")
        // A reply is its message and the request that brought it (as ccusage counts them).
        let id = (message["id"] as? String).map { id in (d["requestId"] as? String).map { "\(id):\($0)" } ?? id }
        return AgentReply(agent: .claudeCode, id: id, time: time, tokens: tokens, output: output,
                          session: d["sessionId"] as? String ?? "", cost: cost)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// "2026-10-09T10:42:39.740Z", with or without the fraction.
    static func date(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }
}

/// Codex's logs (<its folder>/sessions/YYYY/MM/DD/rollout-….jsonl, and archived_sessions/).
public enum CodexLog {
    /// Tokens as Codex counts them: the input includes the cached part, the
    /// output the reasoning.
    public struct Tokens: Equatable, Sendable {
        public var input: Int
        public var cached: Int
        public var output: Int
        public var total: Int

        public init(input: Int, cached: Int, output: Int, total: Int? = nil) {
            self.input = input; self.cached = cached; self.output = output; self.total = total ?? input + output
        }

        static func - (a: Tokens, b: Tokens) -> Tokens {
            Tokens(input: max(0, a.input - b.input), cached: max(0, a.cached - b.cached), output: max(0, a.output - b.output),
                   total: max(0, a.total - b.total))
        }
    }

    public enum Entry: Equatable, Sendable {
        case session(id: String, folder: String, started: Date)
        /// The model its turns use from here on.
        case model(String)
        /// The last reply's tokens and the session's so far, and the plan limits when its server sent them.
        case usage(time: Date, last: Tokens?, total: Tokens?, limits: AgentLimits?)
        /// It started working on what you asked.
        case started(Date)
        /// It finished, and waits for you.
        case finished(Date)
        /// You stopped it, or another task replaced it: it waits for you, but didn't finish.
        case aborted(Date)
    }

    public static func parse(_ line: Data) -> Entry? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = d["payload"] as? [String: Any] else { return nil }
        let time = (d["timestamp"] as? String).flatMap(ClaudeCodeLog.date) ?? .distantPast
        switch (d["type"] as? String, payload["type"] as? String) {
        case ("session_meta", _):
            guard let id = payload["id"] as? String ?? payload["session_id"] as? String else { return nil }
            let started = (payload["timestamp"] as? String).flatMap(ClaudeCodeLog.date) ?? time
            return .session(id: id, folder: payload["cwd"] as? String ?? "", started: started)
        case ("event_msg", "token_count"):
            let info = payload["info"] as? [String: Any]
            let last = tokens(info?["last_token_usage"]), total = tokens(info?["total_token_usage"])
            let limits = Self.limits(payload["rate_limits"], at: time)
            guard last != nil || total != nil || limits != nil else { return nil }
            return .usage(time: time, last: last, total: total, limits: limits)
        case ("turn_context", _):
            return (payload["model"] as? String).map { .model($0) }
        case ("event_msg", "task_started"), ("event_msg", "turn_started"): return .started(time)
        case ("event_msg", "task_complete"), ("event_msg", "turn_complete"): return .finished(time)
        case ("event_msg", "turn_aborted"): return .aborted(time)
        default: return nil
        }
    }

    /// What a token count adds. Codex repeats the last one when nothing more
    /// was used, so it counts only when the session's running total moved; a
    /// count without the last reply's tokens adds the difference.
    public static func added(last: Tokens?, total: Tokens?, previous: Tokens?) -> Tokens? {
        guard let total else { return last }
        guard let previous else { return last ?? total }
        guard total.total > previous.total else { return nil }
        return last ?? total - previous
    }

    private static func tokens(_ value: Any?) -> Tokens? {
        guard let t = value as? [String: Any] else { return nil }
        let input = t["input_tokens"] as? Int ?? 0, output = t["output_tokens"] as? Int ?? 0
        return Tokens(input: input, cached: t["cached_input_tokens"] as? Int ?? 0, output: output, total: t["total_tokens"] as? Int)
    }

    /// The plan's limits: the main ones ("codex"), not a model's own.
    private static func limits(_ value: Any?, at time: Date) -> AgentLimits? {
        guard let r = value as? [String: Any] else { return nil }
        if let id = r["limit_id"] as? String, id != "codex" { return nil }
        func limit(_ value: Any?) -> AgentLimit? {
            guard let l = value as? [String: Any], let used = l["used_percent"] as? Double else { return nil }
            let resets = (l["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (l["resets_in_seconds"] as? Double).map { time.addingTimeInterval($0) }
            return AgentLimit(usedPercent: used, windowMinutes: l["window_minutes"] as? Int, resetsAt: resets)
        }
        let primary = limit(r["primary"]), secondary = limit(r["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return AgentLimits(time: time, primary: primary, secondary: secondary)
    }
}

/// Gemini CLI's chats (<its folder>/tmp/<project>/chats/session-….jsonl, its
/// subagents' in a folder beside them): a line with the session's id, then a
/// line per message. A reply is written again, with the same id, once its
/// tokens are known; lines starting with `$` change earlier ones and aren't
/// messages. Older versions kept each chat in one JSON file.
public enum GeminiChat {
    public enum Line: Equatable, Sendable {
        /// The chat's first line.
        case session(String)
        /// A reply, its session left for the reader to fill in.
        case reply(AgentReply)
    }

    private static let replyKey = Data(#""type":"gemini""#.utf8)
    private static let sessionKey = Data(#""sessionId""#.utf8)
    private static let editKey = Data(#"{"$"#.utf8)

    public static func parse(_ line: Data) -> Line? {
        guard !line.starts(with: editKey), line.range(of: replyKey) != nil || line.range(of: sessionKey) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              !d.keys.contains(where: { $0.hasPrefix("$") }) else { return nil }
        if d["type"] == nil, d["messages"] == nil, let id = d["sessionId"] as? String { return .session(id) }
        return reply(d, session: "").map { .reply($0) }
    }

    /// An older version's whole chat: its replies.
    public static func parseChat(_ data: Data) -> [AgentReply] {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = d["sessionId"] as? String, let messages = d["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { reply($0, session: session) }
    }

    /// Input includes the cached part; thinking is written, so it counts as output.
    static func reply(_ m: [String: Any], session: String) -> AgentReply? {
        guard m["type"] as? String == "gemini", let id = m["id"] as? String, let t = m["tokens"] as? [String: Any],
              let time = (m["timestamp"] as? String).flatMap(ClaudeCodeLog.date) else { return nil }
        func n(_ key: String) -> Int { (t[key] as? NSNumber)?.intValue ?? 0 }
        let output = n("output") + n("thoughts")
        // Tool-use prompts are billed as input.
        let input = n("input") + n("tool")
        let tokens = max(n("total"), input + output)
        let cost = AgentPricing.gemini(model: m["model"] as? String ?? "", input: input, cached: n("cached"), output: output)
        return AgentReply(agent: .gemini, id: "gemini:\(id)", time: time, tokens: tokens, output: output, session: session, cost: cost)
    }
}

/// Antigravity CLI's prompt history (~/.gemini/antigravity-cli/history.jsonl):
/// when, and in which folder; no tokens.
public enum GeminiHistory {
    public static func parse(_ line: Data) -> AgentReply? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = d["timestamp"] as? Double else { return nil }
        let workspace = d["workspace"] as? String ?? ""
        // Known by when it was sent, should the file be written again.
        return AgentReply(agent: .gemini, id: "antigravity:\(Int64(ms))", time: Date(timeIntervalSince1970: ms / 1000), tokens: 0, output: 0,
                          session: workspace, prompt: true)
    }
}

/// OpenCode's messages (a row each in its database, or a JSON file each before
/// version 1.2): a reply's tokens are written as it goes, and are final once
/// it's completed.
public enum OpenCodeMessage {
    /// What a session's last messages say about it.
    public struct Activity: Equatable, Sendable {
        public var state: AgentState
        public var since: Date
        public var interrupted = false

        public init(state: AgentState, since: Date, interrupted: Bool = false) {
            self.state = state; self.since = since; self.interrupted = interrupted
        }
    }

    /// A completed reply, or nil (your messages, and replies still being
    /// written, whose tokens are still 0). Its cost is OpenCode's own, or the
    /// API price when that's 0, as it is with a subscription.
    public static func reply(_ data: Data, id: String, session: String, created: Date) -> AgentReply? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], d["role"] as? String == "assistant",
              let time = d["time"] as? [String: Any], time["completed"] != nil, let t = d["tokens"] as? [String: Any] else { return nil }
        let cache = t["cache"] as? [String: Any] ?? [:]
        func n(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let input = n(t["input"]), output = n(t["output"]) + n(t["reasoning"]), read = n(cache["read"]), write = n(cache["write"])
        let own = (d["cost"] as? NSNumber)?.doubleValue ?? 0
        let cost = own > 0 ? own : AgentPricing.any(model: d["modelID"] as? String ?? "", input: input, cacheWrite: write, cacheRead: read,
                                                     output: output)
        let when = (time["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? created
        return AgentReply(agent: .openCode, id: id, time: when, tokens: input + output + read + write, output: output, session: session,
                          cost: cost)
    }

    /// From a session's last message, when it was last written, and when you
    /// last wrote to it: working while a reply is being written or calls tools
    /// (for up to 10 minutes of quiet), since your message; or waiting since
    /// the reply completed. Nil when the last message is yours.
    public static func activity(_ data: Data, created: Date, written: Date, asked: Date?, now: Date) -> Activity? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], d["role"] as? String == "assistant" else { return nil }
        let time = d["time"] as? [String: Any] ?? [:]
        let started = (time["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? created
        let completed = (time["completed"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let turn = min(asked ?? started, started)
        // A step that called tools is followed by another.
        let more = completed != nil && d["finish"] as? String == "tool-calls"
        if completed == nil || more {
            let quiet = now.timeIntervalSince(max(written, completed ?? started)) >= 10 * 60
            // Gone quiet: waiting, but since the same moment, so it doesn't count as finished.
            return Activity(state: quiet ? .waiting : .working, since: turn)
        }
        let aborted = (d["error"] as? [String: Any])?["name"] as? String == "MessageAbortedError"
        return Activity(state: .waiting, since: completed!, interrupted: aborted)
    }
}

/// What a reply would cost at the provider's API prices, in US dollars per
/// million tokens. Subscriptions (Claude Max, ChatGPT Pro) don't charge per
/// token, so for them it's what the same work would cost through the API.
/// Models without a public price, such as ones running on this Mac, have none (nil).
public enum AgentPricing {
    public struct Price: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheWrite5m: Double
        public var cacheWrite1h: Double
        public var cacheRead: Double

        public init(_ input: Double, _ output: Double, write5m: Double? = nil, write1h: Double? = nil, read: Double) {
            self.input = input; self.output = output
            self.cacheWrite5m = write5m ?? input * 1.25
            self.cacheWrite1h = write1h ?? input * 2
            self.cacheRead = read
        }
    }

    /// platform.claude.com/docs/en/about-claude/pricing, October 2026; the
    /// Claude 3 models at their last listed prices. Longest name first.
    static let claudePrices: [(String, Price)] = [
        ("claude-fable-5-1", Price(10, 50, read: 0.25)), ("claude-mythos-5-1", Price(10, 50, read: 0.25)),
        ("claude-fable-5", Price(10, 50, read: 1)), ("claude-mythos-5", Price(10, 50, read: 1)),
        ("claude-opus-5-5", Price(4, 20, read: 0.20)), ("claude-opus-5", Price(5, 25, read: 0.50)),
        ("claude-opus-4-8", Price(5, 25, read: 0.50)), ("claude-opus-4-7", Price(5, 25, read: 0.50)),
        ("claude-opus-4-6", Price(5, 25, read: 0.50)), ("claude-opus-4-5", Price(5, 25, read: 0.50)),
        ("claude-opus-4-1", Price(15, 75, read: 1.50)), ("claude-opus-4", Price(15, 75, read: 1.50)),
        ("claude-sonnet-5-5", Price(2, 10, read: 0.10)), ("claude-sonnet-5", Price(2, 10, read: 0.20)),
        ("claude-sonnet-4", Price(3, 15, read: 0.30)), ("claude-3-7-sonnet", Price(3, 15, read: 0.30)),
        ("claude-3-5-sonnet", Price(3, 15, read: 0.30)), ("claude-3-opus", Price(15, 75, read: 1.50)),
        ("claude-haiku-5-5", Price(0.10, 0.50, read: 0.01)), ("claude-haiku-4-5", Price(1, 5, read: 0.10)),
        ("claude-3-5-haiku", Price(0.80, 4, read: 0.08)), ("claude-3-haiku", Price(0.25, 1.25, write5m: 0.30, read: 0.03)),
    ].sorted { $0.0.count > $1.0.count }

    /// Haiku 5.5 over 100,000 tokens of prompt.
    static let haikuLong = Price(0.50, 2.50, read: 0.05)

    /// developers.openai.com/api/docs/pricing, October 2026 (short context); the
    /// Codex minis at their last listed prices. Longest name first.
    static let openAIPrices: [(String, Price)] = [
        ("gpt-6.1-sol", Price(2, 10, read: 0.10)), ("gpt-6-astra", Price(10, 50, read: 1)), ("gpt-6-sol", Price(2, 10, read: 0.20)),
        ("gpt-6-luna", Price(0.10, 0.50, read: 0.01)), ("gpt-5.6-sol", Price(4, 20, read: 0.40)), ("gpt-5.6-terra", Price(2, 12, read: 0.20)),
        ("gpt-5.6-luna", Price(0.20, 1.20, read: 0.02)), ("gpt-5.5-pro", Price(30, 180, read: 30)), ("gpt-5.5", Price(5, 30, read: 0.50)),
        ("gpt-5.4-pro", Price(30, 180, read: 30)), ("gpt-5.4-mini", Price(0.75, 4.50, read: 0.075)), ("gpt-5.4-nano", Price(0.20, 1.25, read: 0.02)),
        ("gpt-5.4", Price(2.50, 15, read: 0.25)), ("gpt-5.3-codex", Price(1.75, 14, read: 0.175)), ("gpt-5.2-pro", Price(21, 168, read: 21)),
        ("gpt-5.2", Price(1.75, 14, read: 0.175)), ("gpt-5.1-codex-mini", Price(0.25, 2, read: 0.025)), ("gpt-5.1", Price(1.25, 10, read: 0.125)),
        ("gpt-5-codex-mini", Price(0.25, 2, read: 0.025)), ("gpt-5-mini", Price(0.25, 2, read: 0.025)),
        ("gpt-5-nano", Price(0.05, 0.40, read: 0.005)), ("gpt-5-pro", Price(15, 120, read: 15)), ("gpt-5", Price(1.25, 10, read: 0.125)),
        ("codex-mini-latest", Price(1.50, 6, read: 0.375)), ("gpt-4.1-nano", Price(0.10, 0.40, read: 0.025)),
        ("gpt-4.1-mini", Price(0.40, 1.60, read: 0.10)), ("gpt-4.1", Price(2, 8, read: 0.50)), ("gpt-4o-mini", Price(0.15, 0.60, read: 0.075)),
        ("gpt-4o", Price(2.50, 10, read: 1.25)), ("o4-mini", Price(1.10, 4.40, read: 0.275)), ("o3-mini", Price(1.10, 4.40, read: 0.55)),
        ("o3", Price(2, 8, read: 0.50)),
    ].sorted { $0.0.count > $1.0.count }

    /// ai.google.dev/gemini-api/docs/pricing, October 2026 (paid tier, text). Longest name first.
    static let geminiPrices: [(String, Price)] = [
        ("gemini-3.8-flash", Price(0.75, 3.75, read: 0.075)), ("gemini-3.7-flash", Price(0.75, 3.75, read: 0.075)),
        ("gemini-3.6-flash", Price(0.75, 3.75, read: 0.075)), ("gemini-3.5-flash-lite", Price(0.30, 2.50, read: 0.03)),
        ("gemini-3.5-flash", Price(1.50, 9, read: 0.15)), ("gemini-3.1-pro", Price(2, 12, read: 0.20)),
        ("gemini-3.1-flash-lite", Price(0.25, 1.50, read: 0.025)), ("gemini-3-pro", Price(2, 12, read: 0.20)),
        ("gemini-3-flash", Price(0.50, 3, read: 0.05)), ("gemini-2.5-pro", Price(1.25, 10, read: 0.125)),
        ("gemini-2.5-flash-lite", Price(0.10, 0.40, read: 0.01)), ("gemini-2.5-flash", Price(0.30, 2.50, read: 0.03)),
    ].sorted { $0.0.count > $1.0.count }

    /// The Pro models over 200,000 tokens of prompt.
    static let geminiLong: [(String, Price)] = [
        ("gemini-3.1-pro", Price(4, 18, read: 0.40)), ("gemini-3-pro", Price(4, 18, read: 0.40)), ("gemini-2.5-pro", Price(2.50, 15, read: 0.25)),
    ]

    /// A model's name as the price lists have it: without a provider
    /// ("openai/", "anthropic/"), a cloud's region and version
    /// ("us.anthropic.…-v1:0", "…@20250929") or Claude Code's "[1m]".
    public static func normalize(_ model: String) -> String {
        var m = model.lowercased().trimmingCharacters(in: .whitespaces)
        if m.hasSuffix("[1m]") { m.removeLast(4) }
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let at = m.firstIndex(of: "@") { m = String(m[..<at]) }
        if let region = m.range(of: #"^(us|eu|apac|global|us-gov|jp|au|ca)\."#, options: .regularExpression) { m.removeSubrange(region) }
        if m.hasPrefix("anthropic.") { m.removeFirst("anthropic.".count) }
        if let version = m.range(of: #"-v\d+:\d+$"#, options: .regularExpression) { m.removeSubrange(version) }
        if m.hasPrefix("claude") {
            // Claude's versions are written with dashes; some providers use dots ("claude-sonnet-4.5").
            if let version = m.range(of: #"-v\d+$"#, options: .regularExpression) { m.removeSubrange(version) }
            m = m.replacingOccurrences(of: ".", with: "-")
        }
        return m
    }

    static func price(_ model: String, in table: [(String, Price)]) -> Price? {
        let m = normalize(model)
        return table.first { m.hasPrefix($0.0) }?.1
    }

    /// A Claude reply. Fast mode doubles Opus's prices; US-only inference adds 10%;
    /// a web search is a cent.
    public static func claude(model: String, input: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, output: Int,
                              webSearches: Int = 0, fast: Bool = false, usOnly: Bool = false) -> Double? {
        let m = normalize(model)
        guard var p = price(m, in: claudePrices) else { return nil }
        if m.hasPrefix("claude-haiku-5-5"), input + cacheWrite5m + cacheWrite1h + cacheRead > 100_000 { p = haikuLong }
        var cost = (Double(input) * p.input + Double(cacheWrite5m) * p.cacheWrite5m + Double(cacheWrite1h) * p.cacheWrite1h
            + Double(cacheRead) * p.cacheRead + Double(output) * p.output) / 1_000_000
        if fast, m.hasPrefix("claude-opus") { cost *= 2 }
        if usOnly { cost *= 1.1 }
        return cost + Double(webSearches) * 0.01
    }

    /// An OpenAI reply (Codex): `input` includes the `cached` part.
    public static func openAI(model: String, input: Int, cached: Int, output: Int) -> Double? {
        guard let p = price(model, in: openAIPrices) else { return nil }
        return cachedInput(p, input: input, cached: cached, output: output)
    }

    /// A Gemini reply: `input` includes the `cached` part, `output` the thinking.
    /// The Pro models cost more past 200,000 tokens of prompt.
    public static func gemini(model: String, input: Int, cached: Int, output: Int) -> Double? {
        let m = normalize(model)
        guard var p = price(m, in: geminiPrices) else { return nil }
        if input > 200_000, let long = geminiLong.first(where: { m.hasPrefix($0.0) })?.1 { p = long }
        return cachedInput(p, input: input, cached: cached, output: output)
    }

    /// A reply from any of these providers, by its model (OpenCode): `input`
    /// leaves out what was read from or written to the cache.
    public static func any(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int) -> Double? {
        let m = normalize(model)
        if m.hasPrefix("claude") {
            return claude(model: m, input: input, cacheWrite5m: cacheWrite, cacheWrite1h: 0, cacheRead: cacheRead, output: output)
        }
        if m.hasPrefix("gemini") { return gemini(model: m, input: input + cacheRead + cacheWrite, cached: cacheRead, output: output) }
        return openAI(model: m, input: input + cacheRead + cacheWrite, cached: cacheRead, output: output)
    }

    private static func cachedInput(_ p: Price, input: Int, cached: Int, output: Int) -> Double {
        let cachedPart = min(cached, input)
        return (Double(input - cachedPart) * p.input + Double(cachedPart) * p.cacheRead + Double(output) * p.output) / 1_000_000
    }
}

/// Splits what was appended to a log into whole lines, keeping a partial last
/// line for the next read.
public struct AppendedLines: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func lines(_ chunk: Data) -> [Data] {
        var buffer = pending
        buffer.append(chunk)
        var out: [Data] = []
        var rest = Data()
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            // memchr: logs run to hundreds of megabytes.
            while start < count, let hit = memchr(base + start, 0x0A, count - start) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                if end > start { out.append(Data(bytes: base + start, count: end - start)) }
                start = end + 1
            }
            if start < count { rest = Data(bytes: base + start, count: count - start) }
        }
        pending = rest
        return out
    }
}
