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

    /// Gemini keeps its token counts in a format the island can't read, so it
    /// shows sessions and prompts only.
    public var countsTokens: Bool { self != .gemini }

    /// Where it keeps its files, inside the home folder.
    public var folder: String {
        switch self {
        case .claudeCode: ".claude"
        case .codex: ".codex"
        case .openCode: ".local/share/opencode"
        case .gemini: ".gemini/antigravity-cli"
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
        case .agents: "A row per agent with what it did today and a green dot while it's working. Below, Claude Code's 5-hour window and when it resets."
        case .window: "Claude plans count usage in 5-hour windows. The ring is how far through it you are, with the time left; the medium card adds tokens, replies and sessions."
        case .today: "How hard your agents worked each hour today, with today's totals above."
        case .running: "The sessions open now, by project: working, or waiting for you. Click one to bring its app or terminal forward."
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

    public init(id: String, agent: AgentKind, folder: String, state: AgentState, since: Date, started: Date, pid: Int32? = nil) {
        self.id = id; self.agent = agent; self.folder = folder; self.state = state
        self.since = since; self.started = started; self.pid = pid
    }

    /// The project: the folder's name, or the repository's for a worktree.
    public var project: String {
        let parts = folder.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i >= 2, parts[i - 1] == ".claude" { return parts[i - 2] }
        return parts.last ?? folder
    }
}

/// A session that stopped working and is waiting for you.
public struct AgentFinish: Identifiable, Equatable, Sendable {
    public var id: String
    /// The session's id.
    public var session: String
    public var agent: AgentKind
    public var project: String
    public var duration: TimeInterval

    public init(id: String, session: String, agent: AgentKind, project: String, duration: TimeInterval) {
        self.id = id; self.session = session; self.agent = agent; self.project = project; self.duration = duration
    }

    /// The sessions that were working and now wait for you. One that's gone
    /// (its app quit) didn't finish, so it isn't counted.
    public static func between(_ before: [AgentSession], _ after: [AgentSession], now: Date) -> [AgentFinish] {
        let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return before.compactMap { old in
            guard old.state == .working, let new = current[old.id], new.state == .waiting else { return nil }
            let end = new.since > old.since ? new.since : now
            return AgentFinish(id: "\(old.id)@\(Int(end.timeIntervalSince1970))", session: old.id, agent: old.agent, project: old.project,
                               duration: max(0, end.timeIntervalSince(old.since)))
        }
    }
}

/// Claude Code writes a small file per running session (~/.claude/sessions/<pid>.json):
/// its folder, when it started, and whether it's busy.
public enum ClaudeSessionFile {
    public static func parse(_ data: Data) -> AgentSession? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["sessionId"] as? String else { return nil }
        func date(_ key: String) -> Date? { (d[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let started = date("startedAt") ?? date("updatedAt") ?? .distantPast
        return AgentSession(id: "claudeCode:\(id)", agent: .claudeCode, folder: d["cwd"] as? String ?? "",
                            state: d["status"] as? String == "busy" ? .working : .waiting,
                            since: date("statusUpdatedAt") ?? date("updatedAt") ?? started, started: started,
                            pid: (d["pid"] as? Int).map { Int32($0) })
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
    /// What it would cost at the provider's API prices, in US dollars (see `AgentPricing`).
    public var cost: Double

    public init(agent: AgentKind, id: String?, time: Date, tokens: Int, output: Int, session: String, cost: Double = 0) {
        self.agent = agent; self.id = id; self.time = time; self.tokens = tokens; self.output = output
        self.session = session; self.cost = cost
    }
}

/// A plan limit, as Codex reports it.
public struct AgentLimit: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }
}

/// A day of one agent's work.
public struct AgentDay: Equatable, Sendable {
    /// Tokens per hour of the day.
    public var hours = [Int](repeating: 0, count: 24)
    public var replies = 0
    public var output = 0
    public var sessions: Set<String> = []
    /// In US dollars, at API prices.
    public var cost = 0.0

    public init() {}

    public var tokens: Int { hours.reduce(0, +) }
}

/// Claude's 5-hour window: it opens on the hour of the first reply after the
/// last one closed, and resets five hours later.
public struct AgentWindow: Equatable, Sendable {
    public static let length: TimeInterval = 5 * 3600

    public var start: Date
    public var tokens: Int
    public var cost = 0.0

    public var resets: Date { start.addingTimeInterval(Self.length) }
    public func left(now: Date) -> TimeInterval { max(0, resets.timeIntervalSince(now)) }
    /// How far through it is, 0…1.
    public func fraction(now: Date) -> Double { min(1, max(0, now.timeIntervalSince(start) / Self.length)) }
}

/// The last week of replies, per agent and day, kept as they're read.
public struct AgentLedger: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var time: Date
        public var tokens: Int
        public var cost: Double
    }

    /// A session's spend over the week.
    struct Spend: Equatable, Sendable {
        var cost = 0.0
        var last = Date.distantPast
    }

    public static let keepDays = 8

    public private(set) var days: [AgentKind: [Date: AgentDay]] = [:]
    /// The last day's replies, for the 5-hour window.
    public private(set) var recent: [AgentKind: [Point]] = [:]
    public private(set) var lastUsed: [AgentKind: Date] = [:]
    public var limits: [AgentKind: AgentLimit] = [:]
    private var seen: [String: Date] = [:]
    private var spend: [String: Spend] = [:]
    private let calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Adds a reply; false if it's older than a week or already counted.
    @discardableResult
    public mutating func add(_ reply: AgentReply, now: Date) -> Bool {
        guard reply.time > now.addingTimeInterval(-Double(Self.keepDays) * 86400) else { return false }
        if let id = reply.id {
            guard seen[id] == nil else { return false }
            seen[id] = reply.time
        }
        let day = calendar.startOfDay(for: reply.time)
        let hour = calendar.component(.hour, from: reply.time)
        var d = days[reply.agent]?[day] ?? AgentDay()
        d.hours[hour] += reply.tokens
        d.replies += 1
        d.output += reply.output
        d.cost += reply.cost
        if !reply.session.isEmpty {
            d.sessions.insert(reply.session)
            let key = "\(reply.agent.rawValue):\(reply.session)"
            spend[key, default: Spend()].cost += reply.cost
            if reply.time > spend[key]!.last { spend[key]!.last = reply.time }
        }
        days[reply.agent, default: [:]][day] = d
        if reply.time > now.addingTimeInterval(-86400) {
            recent[reply.agent, default: []].append(Point(time: reply.time, tokens: reply.tokens, cost: reply.cost))
        }
        if reply.time > lastUsed[reply.agent] ?? .distantPast { lastUsed[reply.agent] = reply.time }
        return true
    }

    /// Forgets what's older than the week, and the last day's points past a day.
    public mutating func prune(now: Date) {
        let cutoff = calendar.startOfDay(for: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        for agent in days.keys { days[agent] = days[agent]?.filter { $0.key >= cutoff } }
        seen = seen.filter { $0.value >= cutoff }
        spend = spend.filter { $0.value.last >= cutoff }
        let dayAgo = now.addingTimeInterval(-86400)
        for agent in recent.keys { recent[agent]?.removeAll { $0.time < dayAgo } }
    }

    public func today(_ agent: AgentKind, now: Date) -> AgentDay {
        days[agent]?[calendar.startOfDay(for: now)] ?? AgentDay()
    }

    /// The last seven days, today included.
    public func week(_ agent: AgentKind, now: Date) -> (tokens: Int, replies: Int, sessions: Int, cost: Double) {
        let from = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86400))
        let list = (days[agent] ?? [:]).filter { $0.key >= from }.map(\.value)
        return (list.reduce(0) { $0 + $1.tokens }, list.reduce(0) { $0 + $1.replies },
                list.reduce(into: Set<String>()) { $0.formUnion($1.sessions) }.count, list.reduce(0) { $0 + $1.cost })
    }

    /// What a session has cost over the week, if it replied in it.
    public func cost(of session: AgentSession) -> Double? { spend[session.id]?.cost }

    /// The window open now, if one is.
    public func window(_ agent: AgentKind = .claudeCode, now: Date) -> AgentWindow? {
        var current: AgentWindow?
        for p in (recent[agent] ?? []).sorted(by: { $0.time < $1.time }) {
            if current == nil || p.time >= current!.resets {
                let hour = calendar.dateInterval(of: .hour, for: p.time)?.start ?? p.time
                current = AgentWindow(start: hour, tokens: 0)
            }
            current!.tokens += p.tokens
            current!.cost += p.cost
        }
        guard let current, now < current.resets else { return nil }
        return current
    }
}

// MARK: reading the logs

/// Claude Code's logs (~/.claude/projects/<project>/<session>.jsonl): a line per
/// event; replies carry their token counts.
public enum ClaudeCodeLog {
    /// A reply's usage, or nil for anything else.
    private static let usageKey = Data(#""usage""#.utf8)

    public static func parse(_ line: Data) -> AgentReply? {
        guard line.range(of: usageKey) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant",
              let message = d["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = (d["timestamp"] as? String).flatMap(Self.date) else { return nil }
        func n(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        let output = n("output_tokens")
        let written = n("cache_creation_input_tokens")
        let tokens = n("input_tokens") + written + n("cache_read_input_tokens") + output
        // Cache writes last 5 minutes or an hour, at different prices; older logs don't say which.
        let split = usage["cache_creation"] as? [String: Any]
        let hour = (split?["ephemeral_1h_input_tokens"] as? Int) ?? 0
        let searches = ((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int) ?? 0
        let cost = AgentPricing.claude(model: message["model"] as? String ?? "",
                                       input: n("input_tokens"), cacheWrite5m: max(0, written - hour), cacheWrite1h: hour,
                                       cacheRead: n("cache_read_input_tokens"), output: output, webSearches: searches,
                                       fast: usage["speed"] as? String == "fast", usOnly: usage["inference_geo"] as? String == "us")
        return AgentReply(agent: .claudeCode, id: message["id"] as? String, time: time, tokens: tokens, output: output,
                          session: d["sessionId"] as? String ?? "", cost: cost)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// "2026-10-09T10:42:39.740Z", with or without the fraction.
    static func date(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }
}

/// Codex's logs (~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl).
public enum CodexLog {
    public enum Entry: Equatable, Sendable {
        case session(id: String, folder: String, started: Date)
        /// The model its turns use from here on.
        case model(String)
        /// A reply's tokens (input includes the cached part), and the plan limit when its server sent one.
        case usage(time: Date, input: Int, cached: Int, output: Int, limit: AgentLimit?)
        /// It started working on what you asked.
        case started(Date)
        /// It finished, and waits for you.
        case finished(Date)
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
            let last = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any]
            let limit = (payload["rate_limits"] as? [String: Any])?["primary"] as? [String: Any]
            let parsedLimit = limit.flatMap { l -> AgentLimit? in
                guard let used = l["used_percent"] as? Double else { return nil }
                let resets = (l["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    ?? (l["resets_in_seconds"] as? Double).map { time.addingTimeInterval($0) }
                return AgentLimit(usedPercent: used, windowMinutes: l["window_minutes"] as? Int, resetsAt: resets)
            }
            guard last != nil || parsedLimit != nil else { return nil }
            // Reasoning is part of the output, as total_tokens = input + output shows.
            return .usage(time: time, input: last?["input_tokens"] as? Int ?? 0, cached: last?["cached_input_tokens"] as? Int ?? 0,
                          output: last?["output_tokens"] as? Int ?? 0, limit: parsedLimit)
        case ("turn_context", _):
            return (payload["model"] as? String).map { .model($0) }
        case ("event_msg", "task_started"): return .started(time)
        case ("event_msg", "task_complete"): return .finished(time)
        default: return nil
        }
    }
}

/// What a reply would cost at the provider's API prices, in US dollars per
/// million tokens. Subscriptions (Claude Max, ChatGPT Pro) don't charge per
/// token, so for them it's what the same work would cost through the API.
/// Models not listed, such as ones running on this Mac, count as free.
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

    /// platform.claude.com/docs/en/about-claude/pricing, October 2026. Longest name first.
    static let claudePrices: [(String, Price)] = [
        ("claude-fable-5-1", Price(10, 50, read: 0.25)), ("claude-mythos-5-1", Price(10, 50, read: 0.25)),
        ("claude-fable-5", Price(10, 50, read: 1)), ("claude-mythos-5", Price(10, 50, read: 1)),
        ("claude-opus-5-5", Price(4, 20, read: 0.20)), ("claude-opus-5", Price(5, 25, read: 0.50)),
        ("claude-opus-4-8", Price(5, 25, read: 0.50)), ("claude-opus-4-7", Price(5, 25, read: 0.50)),
        ("claude-opus-4-6", Price(5, 25, read: 0.50)), ("claude-opus-4-5", Price(5, 25, read: 0.50)),
        ("claude-opus-4-1", Price(15, 75, read: 1.50)), ("claude-opus-4", Price(15, 75, read: 1.50)),
        ("claude-sonnet-5-5", Price(2, 10, read: 0.10)), ("claude-sonnet-5", Price(2, 10, read: 0.20)),
        ("claude-sonnet-4", Price(3, 15, read: 0.30)), ("claude-3-7-sonnet", Price(3, 15, read: 0.30)),
        ("claude-haiku-5-5", Price(0.10, 0.50, read: 0.01)), ("claude-haiku-4-5", Price(1, 5, read: 0.10)),
        ("claude-3-5-haiku", Price(0.80, 4, read: 0.08)),
    ].sorted { $0.0.count > $1.0.count }

    /// Haiku 5.5 over 100,000 tokens of prompt.
    static let haikuLong = Price(0.50, 2.50, read: 0.05)

    /// developers.openai.com/api/docs/pricing, October 2026 (short context). Longest name first.
    static let openAIPrices: [(String, Price)] = [
        ("gpt-6.1-sol", Price(2, 10, read: 0.10)), ("gpt-6-astra", Price(10, 50, read: 1)), ("gpt-6-sol", Price(2, 10, read: 0.20)),
        ("gpt-6-luna", Price(0.10, 0.50, read: 0.01)), ("gpt-5.6-sol", Price(4, 20, read: 0.40)), ("gpt-5.6-terra", Price(2, 12, read: 0.20)),
        ("gpt-5.6-luna", Price(0.20, 1.20, read: 0.02)), ("gpt-5.5-pro", Price(30, 180, read: 30)), ("gpt-5.5", Price(5, 30, read: 0.50)),
        ("gpt-5.4-pro", Price(30, 180, read: 30)), ("gpt-5.4-mini", Price(0.75, 4.50, read: 0.075)), ("gpt-5.4-nano", Price(0.20, 1.25, read: 0.02)),
        ("gpt-5.4", Price(2.50, 15, read: 0.25)), ("gpt-5.3-codex", Price(1.75, 14, read: 0.175)), ("gpt-5.2-pro", Price(21, 168, read: 21)),
        ("gpt-5.2", Price(1.75, 14, read: 0.175)), ("gpt-5.1", Price(1.25, 10, read: 0.125)), ("gpt-5-mini", Price(0.25, 2, read: 0.025)),
        ("gpt-5-nano", Price(0.05, 0.40, read: 0.005)), ("gpt-5-pro", Price(15, 120, read: 15)), ("gpt-5", Price(1.25, 10, read: 0.125)),
    ].sorted { $0.0.count > $1.0.count }

    static func price(_ model: String, in table: [(String, Price)]) -> Price? {
        let m = model.lowercased()
        return table.first { m.hasPrefix($0.0) }?.1
    }

    /// A Claude reply. Fast mode doubles Opus's prices; US-only inference adds 10%;
    /// a web search is a cent.
    public static func claude(model: String, input: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, output: Int,
                              webSearches: Int = 0, fast: Bool = false, usOnly: Bool = false) -> Double {
        guard var p = price(model, in: claudePrices) else { return 0 }
        if model.hasPrefix("claude-haiku-5-5"), input + cacheWrite5m + cacheWrite1h + cacheRead > 100_000 { p = haikuLong }
        var cost = (Double(input) * p.input + Double(cacheWrite5m) * p.cacheWrite5m + Double(cacheWrite1h) * p.cacheWrite1h
            + Double(cacheRead) * p.cacheRead + Double(output) * p.output) / 1_000_000
        if fast, model.hasPrefix("claude-opus") { cost *= 2 }
        if usOnly { cost *= 1.1 }
        return cost + Double(webSearches) * 0.01
    }

    /// An OpenAI reply (Codex): `input` includes the `cached` part.
    public static func openAI(model: String, input: Int, cached: Int, output: Int) -> Double {
        guard let p = price(model, in: openAIPrices) else { return 0 }
        let cachedPart = min(cached, input)
        return (Double(input - cachedPart) * p.input + Double(cachedPart) * p.cacheRead + Double(output) * p.output) / 1_000_000
    }
}

/// Gemini's prompt history (~/.gemini/antigravity-cli/history.jsonl): when, and in which folder.
public enum GeminiHistory {
    public static func parse(_ line: Data) -> AgentReply? {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = d["timestamp"] as? Double else { return nil }
        let workspace = d["workspace"] as? String ?? ""
        return AgentReply(agent: .gemini, id: nil, time: Date(timeIntervalSince1970: ms / 1000), tokens: 0, output: 0, session: workspace)
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
