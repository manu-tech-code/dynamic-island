import Foundation
import Testing
@testable import IslandCore

@Suite struct AgentsTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func at(_ s: String) -> Date { try! Date.ISO8601FormatStyle().parse(s) }

    func claudeLine(id: String, time: String, input: Int = 2, cacheRead: Int = 100, output: Int = 50, type: String = "assistant") -> Data {
        Data(#"{"type":"\#(type)","sessionId":"s1","timestamp":"\#(time)","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[{"type":"text","text":"a \"usage\" mention"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":10,"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"server_tool_use":{"web_search_requests":0}}}}"#.utf8)
    }

    @Test func readsClaudeCodeReplies() throws {
        let r = try #require(ClaudeCodeLog.parse(claudeLine(id: "msg_1", time: "2026-10-09T10:42:39.740Z")))
        #expect(r.agent == .claudeCode && r.id == "msg_1" && r.session == "s1")
        #expect(r.tokens == 2 + 10 + 100 + 50 && r.output == 50)
        #expect(r.time == at("2026-10-09T10:42:39Z").addingTimeInterval(0.74))
        // What you typed, and lines without usage, aren't replies.
        #expect(ClaudeCodeLog.parse(claudeLine(id: "msg_2", time: "2026-10-09T10:42:39Z", type: "user")) == nil)
        #expect(ClaudeCodeLog.parse(Data(#"{"type":"assistant","message":{}}"#.utf8)) == nil)
    }

    @Test func countsEachReplyOnce() {
        let now = at("2026-10-09T18:00:00Z")
        var ledger = AgentLedger(calendar: utc)
        let line = { (id: String, time: String) in ClaudeCodeLog.parse(self.claudeLine(id: id, time: time))! }
        // Claude Code writes a reply on several lines: one reply.
        let first = ledger.add(line("msg_1", "2026-10-09T09:10:00Z"), now: now)
        let again = ledger.add(line("msg_1", "2026-10-09T09:10:00Z"), now: now)
        #expect(first && !again)
        ledger.add(line("msg_2", "2026-10-09T09:40:00Z"), now: now)
        ledger.add(line("msg_3", "2026-10-08T23:00:00Z"), now: now)
        // Older than the week: dropped.
        let old = ledger.add(line("msg_old", "2026-09-20T10:00:00Z"), now: now)
        #expect(!old)
        let today = ledger.today(.claudeCode, now: now)
        #expect(today.replies == 2 && today.hours[9] == 2 * 162 && today.tokens == 2 * 162 && today.sessions == ["s1"])
        #expect(ledger.week(.claudeCode, now: now).replies == 3)
        #expect(ledger.lastUsed[.claudeCode] == at("2026-10-09T09:40:00Z"))
    }

    @Test func claudesFiveHourWindow() {
        var ledger = AgentLedger(calendar: utc)
        let now = at("2026-10-09T20:45:00Z")
        for (i, t) in ["2026-10-09T09:05:00Z", "2026-10-09T17:20:00Z", "2026-10-09T18:00:00Z", "2026-10-09T20:30:00Z"].enumerated() {
            ledger.add(AgentReply(agent: .claudeCode, id: "m\(i)", time: at(t), tokens: 100, output: 1, session: "s"), now: now)
        }
        // 09:05's window ended at 14:00; the next opened on the hour of 17:20.
        let w = ledger.window(now: now)
        #expect(w?.start == at("2026-10-09T17:00:00Z") && w?.resets == at("2026-10-09T22:00:00Z") && w?.tokens == 300)
        #expect(w.map { abs($0.fraction(now: now) - 0.75) < 0.001 } == true)
        #expect(w?.left(now: now) == TimeInterval(75 * 60))
        // Past 22:00 with nothing new: no window open.
        #expect(ledger.window(now: at("2026-10-09T22:10:00Z")) == nil)
        // A reply at 22:30 opens the next one at 22:00.
        ledger.add(AgentReply(agent: .claudeCode, id: "m9", time: at("2026-10-09T22:30:00Z"), tokens: 5, output: 1, session: "s"), now: now)
        #expect(ledger.window(now: at("2026-10-09T22:40:00Z"))?.start == at("2026-10-09T22:00:00Z"))
    }

    @Test func readsClaudeCodesRunningSessions() throws {
        let busy = Data(#"{"pid":8890,"sessionId":"e72c","cwd":"/Users/me/dev/dynamic_island","startedAt":1791540961797,"status":"busy","updatedAt":1791542057614,"statusUpdatedAt":1791542000000,"name":"secret title"}"#.utf8)
        let s = try #require(ClaudeSessionFile.parse(busy))
        #expect(s.id == "claudeCode:e72c" && s.state == .working && s.pid == 8890 && s.project == "dynamic_island")
        #expect(s.since == Date(timeIntervalSince1970: 1_791_542_000) && s.started == Date(timeIntervalSince1970: 1_791_540_961.797))
        let idle = Data(#"{"sessionId":"x","cwd":"/Users/me/dev/Agentic_OS/.claude/worktrees/stoic-mirzakhani","status":"idle","startedAt":1}"#.utf8)
        let w = try #require(ClaudeSessionFile.parse(idle))
        #expect(w.state == .waiting && w.project == "Agentic_OS")   // a worktree is its repository's
    }

    @Test func noticesWhenAnAgentFinishes() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func session(_ id: String, _ state: AgentState, since: TimeInterval) -> AgentSession {
            AgentSession(id: id, agent: .claudeCode, folder: "/dev/\(id)", state: state, since: t0.addingTimeInterval(since), started: t0)
        }
        let before = [session("a", .working, since: 0), session("b", .working, since: 10), session("c", .waiting, since: 0)]
        // a finished after 400 s; b is still working; c was already waiting; d is new.
        let after = [session("a", .waiting, since: 400), session("b", .working, since: 10), session("c", .waiting, since: 0), session("d", .working, since: 5)]
        let done = AgentFinish.between(before, after, now: t0.addingTimeInterval(500))
        #expect(done.map(\.project) == ["a"] && done.first?.duration == 400)
        // An app quit mid-work isn't a finish.
        #expect(AgentFinish.between(before, [], now: t0).isEmpty)
    }

    @Test func readsCodex() throws {
        let meta = Data(#"{"timestamp":"2026-09-21T02:09:34.000Z","type":"session_meta","payload":{"id":"01a0","cwd":"/Users/me/dev/app","timestamp":"2026-09-21T02:09:34.000Z"}}"#.utf8)
        #expect(CodexLog.parse(meta) == .session(id: "01a0", folder: "/Users/me/dev/app", started: at("2026-09-21T02:09:34Z")))
        let tokens = Data(#"{"timestamp":"2026-09-21T02:29:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":185922},"last_token_usage":{"input_tokens":18271,"output_tokens":116,"reasoning_output_tokens":30,"total_tokens":18387}},"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1790000000},"secondary":null}}}"#.utf8)
        #expect(CodexLog.parse(tokens) == .usage(time: at("2026-09-21T02:29:15Z"), input: 18271, cached: 0, output: 116,
                                                 limit: AgentLimit(usedPercent: 42.5, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))))
        let turn = Data(#"{"timestamp":"2026-09-21T02:09:35.000Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/x"}}"#.utf8)
        #expect(CodexLog.parse(turn) == .model("gpt-5.5"))
        // Limits the server didn't send.
        let none = Data(#"{"timestamp":"2026-09-21T02:29:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":5,"output_tokens":1}},"rate_limits":{"primary":null}}}"#.utf8)
        #expect(CodexLog.parse(none) == .usage(time: at("2026-09-21T02:29:15Z"), input: 0, cached: 0, output: 1, limit: nil))
        #expect(CodexLog.parse(Data(#"{"timestamp":"2026-09-21T02:30:00Z","type":"event_msg","payload":{"type":"task_complete"}}"#.utf8)) == .finished(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(Data(#"{"timestamp":"2026-09-21T02:30:00Z","type":"response_item","payload":{"type":"message"}}"#.utf8)) == nil)
    }

    @Test func readsGeminiPromptTimes() throws {
        let r = try #require(GeminiHistory.parse(Data(#"{"display":"private prompt","timestamp":1790003912186,"type":"prompt","workspace":"/dev/app"}"#.utf8)))
        #expect(r.agent == .gemini && r.tokens == 0 && r.session == "/dev/app" && r.time == Date(timeIntervalSince1970: 1_790_003_912.186))
    }

    @Test func pricesRepliesAtAPIPrices() throws {
        // Opus 5.5: $4 in, $5 / $8 cache writes (5 min / 1 h), $0.20 cache reads, $20 out, per million.
        let opus = AgentPricing.claude(model: "claude-opus-5-5", input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000,
                                       cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(opus - (4 + 5 + 8 + 0.20 + 20)) < 0.0001)
        // Not mistaken for Opus 5 ($5 / $25), whose name it starts with.
        #expect(abs(AgentPricing.claude(model: "claude-opus-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0) - 5) < 0.0001)
        // Dated names, fast mode (Opus ×2), US-only inference (+10%), web searches.
        #expect(abs(AgentPricing.claude(model: "claude-sonnet-4-5-20250929", input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1_000_000) - 15) < 0.0001)
        #expect(abs(AgentPricing.claude(model: "claude-opus-5-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, fast: true) - 8) < 0.0001)
        #expect(abs(AgentPricing.claude(model: "claude-sonnet-5-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, usOnly: true) - 2.2) < 0.0001)
        #expect(abs(AgentPricing.claude(model: "claude-opus-5-5", input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, webSearches: 3) - 0.03) < 0.0001)
        // Haiku 5.5 costs more past 100,000 tokens of prompt.
        #expect(abs(AgentPricing.claude(model: "claude-haiku-5-5", input: 200_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0) - 0.10) < 0.0001)
        // Unknown and local models are free.
        #expect(AgentPricing.claude(model: "<synthetic>", input: 5, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 5) == 0)
        #expect(AgentPricing.openAI(model: "Qwen3.5-4B-8bit", input: 1000, cached: 0, output: 1000) == 0)
        // Codex: gpt-5.5 at $5 in, $0.50 cached, $30 out; the cached part of the input at the cached price.
        #expect(abs(AgentPricing.openAI(model: "gpt-5.5", input: 1_000_000, cached: 400_000, output: 100_000) - (3 + 0.2 + 3)) < 0.0001)

        // A reply from the log: 1h cache writes priced as such.
        let line = Data(#"{"type":"assistant","sessionId":"s","timestamp":"2026-10-09T10:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":3000,"cache_read_input_tokens":100000,"output_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000},"speed":"standard","inference_geo":"global"}}}"#.utf8)
        let reply = try #require(ClaudeCodeLog.parse(line))
        #expect(abs(reply.cost - (1000 * 4 + 1000 * 5 + 2000 * 8 + 100_000 * 0.20 + 2000 * 20) / 1_000_000) < 0.000001)
    }

    @Test func addsUpCostByDayWindowAndSession() {
        var ledger = AgentLedger(calendar: utc)
        let now = at("2026-10-09T12:00:00Z")
        ledger.add(AgentReply(agent: .claudeCode, id: "a", time: at("2026-10-09T10:00:00Z"), tokens: 10, output: 1, session: "s1", cost: 1.25), now: now)
        ledger.add(AgentReply(agent: .claudeCode, id: "b", time: at("2026-10-09T11:00:00Z"), tokens: 10, output: 1, session: "s2", cost: 0.75), now: now)
        ledger.add(AgentReply(agent: .claudeCode, id: "c", time: at("2026-10-07T11:00:00Z"), tokens: 10, output: 1, session: "s1", cost: 3), now: now)
        #expect(ledger.today(.claudeCode, now: now).cost == 2)
        #expect(ledger.week(.claudeCode, now: now).cost == 5)
        #expect(ledger.window(now: now)?.cost == 2)
        let s1 = AgentSession(id: "claudeCode:s1", agent: .claudeCode, folder: "/a", state: .working, since: now, started: now)
        #expect(ledger.cost(of: s1) == 4.25)
    }

    @Test func formats() {
        #expect(IslandFormat.tokens(950) == "950" && IslandFormat.tokens(12_500) == "12.5K")
        #expect(IslandFormat.dollars(0.4249) == "$0.42" && IslandFormat.dollars(12.4) == "$12.40" && IslandFormat.dollars(123.4) == "$123")
        #expect(IslandFormat.dollars(1234) == "$1.2K" && IslandFormat.dollars(0) == "$0.00")
        #expect(IslandFormat.tokens(489_286_514) == "489.3M" && IslandFormat.tokens(1_156_273_456) == "1.2B")
        #expect(IslandFormat.elapsed(42) == "0:42" && IslandFormat.elapsed(252) == "4:12" && IslandFormat.elapsed(3900) == "1h 05")
        #expect(IslandFormat.took(40) == "40 s" && IslandFormat.took(400) == "6 m 40 s" && IslandFormat.took(360) == "6 m")
        #expect(IslandFormat.took(3900) == "1 h 5 m" && IslandFormat.took(7200) == "2 h")
    }

    @Test func splitsAppendedLines() {
        var s = AppendedLines()
        #expect(s.lines(Data("one\ntw".utf8)) == [Data("one".utf8)])
        #expect(s.lines(Data("o\n\nthree\n".utf8)) == [Data("two".utf8), Data("three".utf8)])
        #expect(s.lines(Data()).isEmpty)
    }

    @Test func settingsDefaultsAndOlderFiles() throws {
        let s = IslandSettings()
        #expect(s.agents.card == .agents && s.agents.showWorking && s.agents.alertWhenDone && s.agents.showCost)
        #expect(AgentKind.allCases.allSatisfy { s.agents.isOn($0) })
        #expect(s[module: .agents].enabled && DashboardWidgetKind.agents.module == .agents)
        // Saved before agents existed: they go in after timers, like the other live work; the defaults fill in.
        let saved = #"{"priority":["calendar","nowPlaying","timer","messages","downloads"],"agents":{"card":"running"}}"#
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(saved.utf8))
        #expect(old.priority.prefix(5) == [.calendar, .nowPlaying, .timer, .agents, .messages])
        #expect(old.agents.card == .running && old.agents.alertMinimumSeconds == 30)
        var t = IslandSettings()
        t.agents.alertMinimumSeconds = -5
        t.agents.agents["codex"] = false
        let back = IslandSettings.decode(t.encoded())
        #expect(back.agents.alertMinimumSeconds == 0 && !back.agents.isOn(.codex) && back.agents.isOn(.claudeCode))
    }
}
