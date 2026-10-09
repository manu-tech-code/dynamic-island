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

    func claudeLine(id: String, time: String, input: Int = 2, cacheRead: Int = 100, output: Int = 50, type: String = "assistant",
                    model: String = "claude-opus-5-5", extra: String = "") -> Data {
        Data(#"{"type":"\#(type)","sessionId":"s1",\#(extra)"timestamp":"\#(time)","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"a \"usage\" mention"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":10,"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"server_tool_use":{"web_search_requests":0}}}}"#.utf8)
    }

    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000001 } ?? false }

    @Test func readsClaudeCodeReplies() throws {
        let r = try #require(ClaudeCodeLog.parse(claudeLine(id: "msg_1", time: "2026-10-09T10:42:39.740Z")))
        #expect(r.agent == .claudeCode && r.id == "msg_1" && r.session == "s1")
        #expect(r.tokens == 2 + 10 + 100 + 50 && r.output == 50)
        #expect(r.time == at("2026-10-09T10:42:39Z").addingTimeInterval(0.74))
        // What you typed, and lines without usage, aren't replies.
        #expect(ClaudeCodeLog.parse(claudeLine(id: "msg_2", time: "2026-10-09T10:42:39Z", type: "user")) == nil)
        #expect(ClaudeCodeLog.parse(Data(#"{"type":"assistant","message":{}}"#.utf8)) == nil)
        // Notes Claude Code writes itself, and API errors, aren't replies either.
        #expect(ClaudeCodeLog.parse(claudeLine(id: "msg_3", time: "2026-10-09T10:42:39Z", model: "<synthetic>")) == nil)
        #expect(ClaudeCodeLog.parse(claudeLine(id: "msg_4", time: "2026-10-09T10:42:39Z", extra: #""isApiErrorMessage":true,"#)) == nil)
        // A reply is its message and its request.
        let withRequest = try #require(ClaudeCodeLog.parse(claudeLine(id: "msg_5", time: "2026-10-09T10:42:39Z", extra: #""requestId":"req_9","#)))
        #expect(withRequest.id == "msg_5:req_9")
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

    @Test func keepsTheFullerCopyOfAReply() throws {
        let now = at("2026-10-09T12:00:00Z")
        var ledger = AgentLedger(calendar: utc)
        // The first line of a reply can carry only part of its output.
        let partial = try #require(ClaudeCodeLog.parse(claudeLine(id: "msg_1", time: "2026-10-09T11:00:00Z", output: 5)))
        let full = try #require(ClaudeCodeLog.parse(claudeLine(id: "msg_1", time: "2026-10-09T11:00:00Z", output: 500)))
        let first = ledger.add(partial, now: now)
        let fuller = ledger.add(full, now: now)
        // A smaller copy after the full one changes nothing.
        let smaller = ledger.add(partial, now: now)
        #expect(first && fuller && !smaller)
        let today = ledger.today(.claudeCode, now: now)
        #expect(today.replies == 1 && today.output == 500 && today.tokens == full.tokens)
        #expect(near(today.cost, full.cost!))
        #expect(ledger.window(now: now)?.tokens == full.tokens && near(ledger.window(now: now)?.cost, full.cost!))
        let session = AgentSession(id: "claudeCode:s1", agent: .claudeCode, folder: "/a", state: .working, since: now, started: now)
        #expect(near(ledger.cost(of: session)?.cost, full.cost!))
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

    @Test func windowsOpenOnTheHourInUTC() {
        // In India (+5:30) the local hour starts at half past the UTC one.
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var ledger = AgentLedger(calendar: india)
        let now = at("2026-10-09T10:30:00Z")
        ledger.add(AgentReply(agent: .claudeCode, id: "m", time: at("2026-10-09T10:20:00Z"), tokens: 1, output: 1, session: "s"), now: now)
        #expect(ledger.window(now: now)?.start == at("2026-10-09T10:00:00Z"))
        #expect(ledger.window(now: now)?.resets == at("2026-10-09T15:00:00Z"))
    }

    @Test func readsClaudeCodesRunningSessions() throws {
        let busy = Data(#"{"pid":8890,"sessionId":"e72c","cwd":"/Users/me/dev/dynamic_island","startedAt":1791540961797,"procStart":"Fri Oct  9 10:16:01 2026","kind":"interactive","pidDomain":"darwin","status":"busy","updatedAt":1791542057614,"statusUpdatedAt":1791542000000,"name":"secret title"}"#.utf8)
        let (s, start) = try #require(ClaudeSessionFile.parse(busy, timeZone: TimeZone(identifier: "UTC")!))
        #expect(s.id == "claudeCode:e72c" && s.state == .working && s.pid == 8890 && s.project == "dynamic_island" && s.reason == nil)
        #expect(s.since == Date(timeIntervalSince1970: 1_791_542_000) && s.started == Date(timeIntervalSince1970: 1_791_540_961.797))
        #expect(start == at("2026-10-09T10:16:01Z"))
        let idle = Data(#"{"sessionId":"x","cwd":"/Users/me/dev/Agentic_OS/.claude/worktrees/stoic-mirzakhani","status":"idle","startedAt":1}"#.utf8)
        let w = try #require(ClaudeSessionFile.parse(idle)?.session)
        #expect(w.state == .waiting && w.project == "Agentic_OS")   // a worktree is its repository's
        #expect(ClaudeSessionFile.parse(idle)?.processStart == nil)
        // Waiting for you, and for what.
        let asking = Data(#"{"sessionId":"y","cwd":"/a","status":"waiting","waitingFor":"approve Bash","statusUpdatedAt":5000}"#.utf8)
        let n = try #require(ClaudeSessionFile.parse(asking)?.session)
        #expect(n.state == .needsYou && n.reason == "approve Bash" && n.since == Date(timeIntervalSince1970: 5))
        // Background and spare sessions, and another machine's, aren't shown.
        for other in [#""kind":"bg""#, #""spare":true"#, #""pidDomain":"linux""#] {
            #expect(ClaudeSessionFile.parse(Data(#"{"sessionId":"z","cwd":"/a","status":"busy",\#(other)}"#.utf8)) == nil)
        }
        #expect(ClaudeSessionFile.parse(Data(#"{"sessionId":"z","cwd":"/a","status":"busy","spare":false}"#.utf8)) != nil)
    }

    @Test func tellsAProcessFromALaterOneWithItsNumber() {
        let written = ClaudeSessionFile.processStart("Fri Oct  9 07:34:57 2026", timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(written == at("2026-10-09T02:04:57Z"))
        #expect(ClaudeSessionFile.isSameProcess(written: written, running: at("2026-10-09T02:04:57Z").addingTimeInterval(0.6)))
        #expect(!ClaudeSessionFile.isSameProcess(written: written, running: at("2026-10-09T05:00:00Z")))
        #expect(!ClaudeSessionFile.isSameProcess(written: written, running: nil))
        // A file that doesn't say is believed.
        #expect(ClaudeSessionFile.isSameProcess(written: nil, running: nil))
        // Started in India, read after a flight to London: the same process if it ran when the file was written.
        let london = ClaudeSessionFile.processStart("Fri Oct  9 07:34:57 2026", timeZone: TimeZone(identifier: "Europe/London")!)
        let running = at("2026-10-09T02:04:57Z")
        #expect(ClaudeSessionFile.isSameProcess(written: london, running: running, fileWritten: at("2026-10-09T09:00:00Z")))
        #expect(!ClaudeSessionFile.isSameProcess(written: london, running: running, fileWritten: at("2026-10-09T01:00:00Z")))
    }

    @Test func noticesWhenAnAgentFinishes() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func session(_ id: String, _ state: AgentState, since: TimeInterval, reason: String? = nil, interrupted: Bool = false) -> AgentSession {
            AgentSession(id: id, agent: .claudeCode, folder: "/dev/\(id)", state: state, since: t0.addingTimeInterval(since), started: t0,
                         reason: reason, interrupted: interrupted)
        }
        let before = [session("a", .working, since: 0), session("b", .working, since: 10), session("c", .waiting, since: 0)]
        // a finished after 400 s; b is still working; c was already waiting; d is new.
        let after = [session("a", .waiting, since: 400), session("b", .working, since: 10), session("c", .waiting, since: 0), session("d", .working, since: 5)]
        let done = AgentFinish.between(before, after)
        #expect(done.map(\.project) == ["a"] && done.first?.duration == 400 && done.first?.needsYou == false)
        // An app quit mid-work isn't a finish.
        #expect(AgentFinish.between(before, []).isEmpty)
        // Gone quiet (no new moment), or stopped by you: not finished either.
        #expect(AgentFinish.between(before, [session("a", .waiting, since: 0)]).isEmpty)
        #expect(AgentFinish.between(before, [session("a", .waiting, since: 400, interrupted: true)]).isEmpty)
        // Stopped to ask you something: it needs you, and says what.
        let asks = AgentFinish.between(before, [session("a", .needsYou, since: 60, reason: "approve Bash")])
        #expect(asks.count == 1 && asks[0].needsYou && asks[0].reason == "approve Bash" && asks[0].duration == 60)
        #expect(asks[0].id != done[0].id)
    }

    @Test func readsCodex() throws {
        let meta = Data(#"{"timestamp":"2026-09-21T02:09:34.000Z","type":"session_meta","payload":{"id":"01a0","cwd":"/Users/me/dev/app","timestamp":"2026-09-21T02:09:34.000Z"}}"#.utf8)
        #expect(CodexLog.parse(meta) == .session(id: "01a0", folder: "/Users/me/dev/app", started: at("2026-09-21T02:09:34Z")))
        let tokens = Data(#"{"timestamp":"2026-09-21T02:29:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180000,"cached_input_tokens":90000,"output_tokens":5922,"total_tokens":185922},"last_token_usage":{"input_tokens":18271,"cached_input_tokens":16384,"output_tokens":116,"reasoning_output_tokens":30,"total_tokens":18387}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1790000000},"secondary":{"used_percent":12,"window_minutes":10080,"resets_at":1790500000}}}}"#.utf8)
        let limits = AgentLimits(time: at("2026-09-21T02:29:15Z"),
                                 primary: AgentLimit(usedPercent: 42.5, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_790_000_000)),
                                 secondary: AgentLimit(usedPercent: 12, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_790_500_000)))
        #expect(CodexLog.parse(tokens) == .usage(time: at("2026-09-21T02:29:15Z"),
                                                 last: CodexLog.Tokens(input: 18271, cached: 16384, output: 116, total: 18387),
                                                 total: CodexLog.Tokens(input: 180_000, cached: 90000, output: 5922, total: 185_922), limits: limits))
        #expect(limits.primary?.name == "5 h" && limits.secondary?.name == "week")
        let turn = Data(#"{"timestamp":"2026-09-21T02:09:35.000Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/x"}}"#.utf8)
        #expect(CodexLog.parse(turn) == .model("gpt-5.5"))
        // Limits the server didn't send, and a model's own limits, aren't the plan's.
        let none = Data(#"{"timestamp":"2026-09-21T02:29:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":5,"output_tokens":1}},"rate_limits":{"primary":null}}}"#.utf8)
        #expect(CodexLog.parse(none) == .usage(time: at("2026-09-21T02:29:15Z"), last: CodexLog.Tokens(input: 0, cached: 0, output: 1, total: 5), total: nil, limits: nil))
        let other = Data(#"{"timestamp":"2026-09-21T02:29:15.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_other","primary":{"used_percent":3}}}}"#.utf8)
        #expect(CodexLog.parse(other) == nil)
        // Turns: both names, and one you stopped.
        func event(_ type: String) -> Data { Data(#"{"timestamp":"2026-09-21T02:30:00Z","type":"event_msg","payload":{"type":"\#(type)","reason":"interrupted"}}"#.utf8) }
        #expect(CodexLog.parse(event("task_started")) == .started(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(event("turn_started")) == .started(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(event("task_complete")) == .finished(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(event("turn_complete")) == .finished(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(event("turn_aborted")) == .aborted(at("2026-09-21T02:30:00Z")))
        #expect(CodexLog.parse(Data(#"{"timestamp":"2026-09-21T02:30:00Z","type":"response_item","payload":{"type":"message"}}"#.utf8)) == nil)
    }

    @Test func countsARepeatedCodexTokenCountOnce() {
        typealias T = CodexLog.Tokens
        let last = T(input: 13109, cached: 12288, output: 237, total: 13346)
        let total = T(input: 60000, cached: 40000, output: 2000, total: 62000)
        // The first count in a log, then the same one again after a stopped turn.
        #expect(CodexLog.added(last: last, total: total, previous: nil) == last)
        #expect(CodexLog.added(last: last, total: total, previous: total) == nil)
        // The total moved: the last reply's tokens.
        let next = T(input: 75000, cached: 52000, output: 2300, total: 77300)
        let reply = T(input: 15000, cached: 12000, output: 300, total: 15300)
        #expect(CodexLog.added(last: reply, total: next, previous: total) == reply)
        // Without the last reply's tokens: the difference.
        #expect(CodexLog.added(last: nil, total: next, previous: total) == T(input: 15000, cached: 12000, output: 300, total: 15300))
        // Older logs without a running total.
        #expect(CodexLog.added(last: reply, total: nil, previous: nil) == reply)
    }

    @Test func keepsCodexsNewestLimitsUntilTheyReset() {
        var ledger = AgentLedger(calendar: utc)
        let newer = AgentLimits(time: at("2026-10-09T10:00:00Z"), primary: AgentLimit(usedPercent: 40, windowMinutes: 300, resetsAt: at("2026-10-09T12:00:00Z")),
                                secondary: AgentLimit(usedPercent: 10, windowMinutes: 10080, resetsAt: at("2026-10-12T00:00:00Z")))
        let older = AgentLimits(time: at("2026-10-08T10:00:00Z"), primary: AgentLimit(usedPercent: 90, windowMinutes: 300), secondary: nil)
        // Logs are read in no particular order: the newest stays.
        ledger.note(newer, for: .codex)
        ledger.note(older, for: .codex)
        #expect(ledger.limits(.codex, now: at("2026-10-09T11:00:00Z")).map(\.usedPercent) == [40, 10])
        // Once the 5-hour one resets, only the week's is left.
        #expect(ledger.limits(.codex, now: at("2026-10-09T13:00:00Z")).map(\.usedPercent) == [10])
        #expect(ledger.limits(.codex, now: at("2026-10-13T00:00:00Z")).isEmpty)
    }

    @Test func readsGeminiCLIChats() throws {
        let meta = Data(#"{"sessionId":"5f1c","projectHash":"ab12","startTime":"2026-10-09T10:00:00.000Z","lastUpdated":"2026-10-09T10:00:00.000Z","kind":"main"}"#.utf8)
        #expect(GeminiChat.parse(meta) == .session("5f1c"))
        // A reply is written first without its tokens, then again with them.
        let early = Data(#"{"id":"m1","timestamp":"2026-10-09T10:01:00.000Z","type":"gemini","content":[{"text":"private"}],"model":"gemini-2.5-pro","tokens":null}"#.utf8)
        #expect(GeminiChat.parse(early) == nil)
        let line = Data(#"{"id":"m1","timestamp":"2026-10-09T10:01:00.000Z","type":"gemini","content":[{"text":"private"}],"model":"gemini-2.5-pro","tokens":{"input":1000,"output":200,"cached":400,"thoughts":50,"tool":10,"total":1260}}"#.utf8)
        guard case .reply(let r)? = GeminiChat.parse(line) else { Issue.record("not a reply"); return }
        #expect(r.agent == .gemini && r.id == "gemini:m1" && r.time == at("2026-10-09T10:01:00Z"))
        #expect(r.tokens == 1260 && r.output == 250)
        // 2.5 Pro: input (with the tool prompt) less the cached part at $1.25, cached at $0.125, output and thinking at $10.
        let price: Double = (610 * 1.25 + 400 * 0.125 + 250 * 10) / 1_000_000
        #expect(near(r.cost, price))
        // What you typed, and edits to earlier lines, aren't replies.
        #expect(GeminiChat.parse(Data(#"{"id":"u1","timestamp":"2026-10-09T10:00:30.000Z","type":"user","content":[{"text":"private"}]}"#.utf8)) == nil)
        for edit in [#"{"$rewindTo":"m1"}"#, #"{"$patch":{"id":"m1","content":[]}}"#,
                     #"{"$set":{"sessionId":"5f1c","messages":[{"id":"m1","timestamp":"2026-10-09T10:01:00.000Z","type":"gemini","tokens":{"input":1,"output":1,"cached":0,"total":2}}]}}"#] {
            #expect(GeminiChat.parse(Data(edit.utf8)) == nil)
        }
        // Counted once, with its tokens.
        var ledger = AgentLedger(calendar: utc)
        let now = at("2026-10-09T12:00:00Z")
        ledger.add(r, now: now)
        ledger.add(r, now: now)
        #expect(ledger.today(.gemini, now: now).replies == 1 && ledger.today(.gemini, now: now).tokens == 1260)

        // Older versions: the whole chat in one file.
        let chat = Data(#"{"sessionId":"old1","projectHash":"ab","startTime":"2026-10-09T09:00:00.000Z","lastUpdated":"2026-10-09T09:05:00.000Z","messages":[{"id":"u","timestamp":"2026-10-09T09:00:00.000Z","type":"user","content":"private"},{"id":"g","timestamp":"2026-10-09T09:01:00.000Z","type":"gemini","content":"private","model":"gemini-2.5-flash","tokens":{"input":100,"output":10,"cached":0,"thoughts":0,"tool":0,"total":110}}]}"#.utf8)
        let replies = GeminiChat.parseChat(chat)
        #expect(replies.count == 1 && replies[0].session == "old1" && replies[0].tokens == 110 && near(replies[0].cost, (100 * 0.30 + 10 * 2.50) / 1_000_000))
    }

    @Test func readsAntigravityPromptTimes() throws {
        let r = try #require(GeminiHistory.parse(Data(#"{"display":"private prompt","timestamp":1790003912186,"type":"prompt","workspace":"/dev/app"}"#.utf8)))
        #expect(r.agent == .gemini && r.tokens == 0 && r.prompt && r.session == "/dev/app" && r.time == Date(timeIntervalSince1970: 1_790_003_912.186))
        // Prompts, not replies; once each, should the history be read again.
        var ledger = AgentLedger(calendar: utc)
        ledger.add(r, now: r.time)
        ledger.add(r, now: r.time)
        #expect(ledger.today(.gemini, now: r.time).prompts == 1 && ledger.today(.gemini, now: r.time).replies == 0)
    }

    @Test func readsOpenCodeReplies() throws {
        let created = at("2026-10-09T10:00:00Z")
        // Still being written: its tokens are still 0, so it isn't counted yet.
        let writing = Data(#"{"role":"assistant","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-4-5","providerID":"anthropic","time":{"created":1791540000000}}"#.utf8)
        #expect(OpenCodeMessage.reply(writing, id: "opencode:m", session: "s", created: created) == nil)
        // Done, priced by OpenCode.
        let paid = Data(#"{"role":"assistant","cost":0.25,"tokens":{"input":1000,"output":100,"reasoning":20,"cache":{"read":5000,"write":0}},"modelID":"claude-sonnet-4-5","providerID":"anthropic","time":{"created":1791540000000,"completed":1791540005000}}"#.utf8)
        let r = try #require(OpenCodeMessage.reply(paid, id: "opencode:m", session: "s", created: created))
        #expect(r.tokens == 1000 + 120 + 5000 && r.output == 120 && r.cost == 0.25 && r.time == Date(timeIntervalSince1970: 1_791_540_000))
        // A subscription's replies cost 0 in OpenCode: then the API's price.
        let subscription = Data(#"{"role":"assistant","cost":0,"tokens":{"input":1000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"claude-sonnet-4.5","providerID":"github-copilot","time":{"created":1791540000000,"completed":1791540005000}}"#.utf8)
        #expect(near(OpenCodeMessage.reply(subscription, id: "m", session: "s", created: created)?.cost, (1000 * 3 + 100 * 15) / 1_000_000))
        // A model on this Mac has no price.
        let local = Data(#"{"role":"assistant","cost":0,"tokens":{"input":60,"output":63,"reasoning":0,"cache":{"read":10444,"write":0}},"modelID":"qwen3.6-35b-a3b","providerID":"local","time":{"created":1791540000000,"completed":1791540005000}}"#.utf8)
        let free = try #require(OpenCodeMessage.reply(local, id: "m", session: "s", created: created))
        #expect(free.cost == nil && free.unpriced == 10567)
        #expect(OpenCodeMessage.reply(Data(#"{"role":"user","time":{"created":1}}"#.utf8), id: "m", session: "s", created: created) == nil)
    }

    @Test func tellsWhatAnOpenCodeSessionIsDoing() {
        let asked = Date(timeIntervalSince1970: 1_791_539_990)
        let created = Date(timeIntervalSince1970: 1_791_540_000)
        let now = Date(timeIntervalSince1970: 1_791_540_060)
        func message(_ time: String, extra: String = "") -> Data {
            Data(#"{"role":"assistant","time":{\#(time)},"tokens":{"input":0,"output":0}\#(extra)}"#.utf8)
        }
        // Writing, or between steps that call tools: working since you asked.
        let writing = OpenCodeMessage.activity(message(#""created":1791540000000"#), created: created, written: now, asked: asked, now: now)
        #expect(writing == OpenCodeMessage.Activity(state: .working, since: asked))
        let tools = OpenCodeMessage.activity(message(#""created":1791540000000,"completed":1791540050000"#, extra: #","finish":"tool-calls""#),
                                             created: created, written: now, asked: asked, now: now)
        #expect(tools?.state == .working)
        // Done: waiting since it completed; stopped by you: no finish.
        let done = OpenCodeMessage.activity(message(#""created":1791540000000,"completed":1791540050000"#, extra: #","finish":"stop""#),
                                            created: created, written: now, asked: asked, now: now)
        #expect(done == OpenCodeMessage.Activity(state: .waiting, since: Date(timeIntervalSince1970: 1_791_540_050)))
        let stopped = OpenCodeMessage.activity(message(#""created":1791540000000,"completed":1791540050000"#, extra: #","error":{"name":"MessageAbortedError"}"#),
                                               created: created, written: now, asked: asked, now: now)
        #expect(stopped?.interrupted == true)
        // Quiet for 10 minutes: waiting, from the same moment, so it isn't a finish.
        let quiet = OpenCodeMessage.activity(message(#""created":1791540000000"#), created: created, written: created, asked: asked,
                                             now: created.addingTimeInterval(11 * 60))
        #expect(quiet == OpenCodeMessage.Activity(state: .waiting, since: asked))
    }

    @Test func pricesRepliesAtAPIPrices() throws {
        // Opus 5.5: $4 in, $5 / $8 cache writes (5 min / 1 h), $0.20 cache reads, $20 out, per million.
        let opus = AgentPricing.claude(model: "claude-opus-5-5", input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000,
                                       cacheRead: 1_000_000, output: 1_000_000)
        #expect(near(opus, 4 + 5 + 8 + 0.20 + 20))
        // Not mistaken for Opus 5 ($5 / $25), whose name it starts with.
        #expect(near(AgentPricing.claude(model: "claude-opus-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0), 5))
        // Dated names, fast mode (Opus ×2), US-only inference (+10%), web searches.
        #expect(near(AgentPricing.claude(model: "claude-sonnet-4-5-20250929", input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1_000_000), 15))
        #expect(near(AgentPricing.claude(model: "claude-opus-5-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, fast: true), 8))
        #expect(near(AgentPricing.claude(model: "claude-sonnet-5-5", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, usOnly: true), 2.2))
        #expect(near(AgentPricing.claude(model: "claude-opus-5-5", input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0, webSearches: 3), 0.03))
        // Haiku 5.5 costs more past 100,000 tokens of prompt.
        #expect(near(AgentPricing.claude(model: "claude-haiku-5-5", input: 200_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0), 0.10))
        // Unknown and local models have no price.
        #expect(AgentPricing.claude(model: "<synthetic>", input: 5, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 5) == nil)
        #expect(AgentPricing.openAI(model: "Qwen3.5-4B-8bit", input: 1000, cached: 0, output: 1000) == nil)
        #expect(AgentPricing.gemini(model: "gemma-3-27b", input: 1000, cached: 0, output: 1000) == nil)
        // Codex: gpt-5.5 at $5 in, $0.50 cached, $30 out; the cached part of the input at the cached price.
        #expect(near(AgentPricing.openAI(model: "gpt-5.5", input: 1_000_000, cached: 400_000, output: 100_000), 3 + 0.2 + 3))

        // A reply from the log: 1h cache writes priced as such.
        let line = Data(#"{"type":"assistant","sessionId":"s","timestamp":"2026-10-09T10:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":3000,"cache_read_input_tokens":100000,"output_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000},"speed":"standard","inference_geo":"global"}}}"#.utf8)
        let reply = try #require(ClaudeCodeLog.parse(line))
        let price: Double = (1000 * 4 + 1000 * 5 + 2000 * 8 + 100_000 * 0.20 + 2000 * 20) / 1_000_000
        #expect(near(reply.cost, price))
    }

    @Test func pricesModelsByTheirPlainNames() {
        let names = [
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5-20250929"),
            ("global.anthropic.claude-opus-4-6-v1", "claude-opus-4-6"),
            ("anthropic.claude-3-5-sonnet-20241022-v2:0", "claude-3-5-sonnet-20241022"),
            ("claude-3-5-sonnet-v2@20241022", "claude-3-5-sonnet"),
            ("claude-opus-4-6[1m]", "claude-opus-4-6"),
            ("anthropic/claude-sonnet-4.5", "claude-sonnet-4-5"),
            ("openai/gpt-5.1-codex", "gpt-5.1-codex"),
            ("models/gemini-2.5-pro", "gemini-2.5-pro"),
            ("GPT-5.5", "gpt-5.5"),
        ]
        for (raw, plain) in names { #expect(AgentPricing.normalize(raw) == plain, "\(raw)") }
        #expect(near(AgentPricing.claude(model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0", input: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0), 3))
        #expect(near(AgentPricing.openAI(model: "openai/gpt-5.5", input: 1_000_000, cached: 0, output: 0), 5))
    }

    @Test func pricesOlderAndSmallerModels() {
        func openAI(_ model: String) -> Double? { AgentPricing.openAI(model: model, input: 2_000_000, cached: 1_000_000, output: 1_000_000) }
        func claude(_ model: String) -> Double? {
            AgentPricing.claude(model: model, input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 0, cacheRead: 1_000_000, output: 1_000_000)
        }
        // A million each of new input, cached input and output.
        #expect(near(openAI("gpt-5.1-codex-mini"), 0.25 + 0.025 + 2))   // not gpt-5.1's $1.25 / $10
        #expect(near(openAI("gpt-5.1-codex"), 1.25 + 0.125 + 10))
        #expect(near(openAI("gpt-4.1"), 2 + 0.50 + 8))
        #expect(near(openAI("gpt-4.1-mini-2025-04-14"), 0.40 + 0.10 + 1.60))
        #expect(near(openAI("gpt-4.1-nano"), 0.10 + 0.025 + 0.40))
        #expect(near(openAI("o3"), 2 + 0.50 + 8))
        #expect(near(openAI("o4-mini"), 1.10 + 0.275 + 4.40))
        #expect(near(openAI("codex-mini-latest"), 1.50 + 0.375 + 6))
        // A million each of input, 5-minute cache writes, cache reads and output.
        #expect(near(claude("claude-3-5-sonnet-20241022"), 3 + 3.75 + 0.30 + 15))
        #expect(near(claude("claude-3-opus-20240229"), 15 + 18.75 + 1.50 + 75))
        #expect(near(claude("claude-3-haiku-20240307"), 0.25 + 0.30 + 0.03 + 1.25))
        // Gemini: 2.5 Pro costs more past 200,000 tokens of prompt.
        #expect(near(AgentPricing.gemini(model: "gemini-2.5-pro", input: 100_000, cached: 0, output: 0), 0.125))
        #expect(near(AgentPricing.gemini(model: "gemini-2.5-pro", input: 300_000, cached: 0, output: 0), 0.75))
        #expect(near(AgentPricing.gemini(model: "gemini-3-flash-preview", input: 1_000_000, cached: 500_000, output: 1_000_000), 0.25 + 0.025 + 3))
        #expect(near(AgentPricing.gemini(model: "gemini-2.5-flash-lite", input: 1_000_000, cached: 0, output: 0), 0.10))
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
        #expect(ledger.cost(of: s1)?.cost == 4.25 && ledger.cost(of: s1)?.unpriced == 0)
    }

    @Test func keepsTokensWithoutAPriceApart() {
        var ledger = AgentLedger(calendar: utc)
        let now = at("2026-10-09T12:00:00Z")
        ledger.add(AgentReply(agent: .openCode, id: "a", time: at("2026-10-09T10:00:00Z"), tokens: 100, output: 1, session: "s1", cost: 0.5), now: now)
        ledger.add(AgentReply(agent: .openCode, id: "b", time: at("2026-10-09T11:00:00Z"), tokens: 700, output: 1, session: "s1", cost: nil), now: now)
        let today = ledger.today(.openCode, now: now)
        #expect(today.tokens == 800 && today.cost == 0.5 && today.unpriced == 700)
        #expect(ledger.week(.openCode, now: now).unpriced == 700)
        #expect(ledger.window(.openCode, now: now)?.unpriced == 700)
        let s1 = AgentSession(id: "openCode:s1", agent: .openCode, folder: "/a", state: .working, since: now, started: now)
        #expect(ledger.cost(of: s1)?.unpriced == 700)
        // At least the part with a price; nothing when none had one.
        let us = Locale(identifier: "en_US")
        #expect(IslandFormat.cost(0.5, unpriced: 700, locale: us) == "≥ $0.50")
        #expect(IslandFormat.cost(0, unpriced: 700, locale: us) == "—")
        #expect(IslandFormat.cost(0.5, unpriced: 0, locale: us) == "$0.50")
    }

    @Test func findsTheAgentsFolders() {
        let home = "/Users/me"
        let usual = AgentFolders(home: home)
        #expect(usual.claude == ["/Users/me/.config/claude", "/Users/me/.claude"] && usual.claudeAccounts == ["/Users/me/.claude.json"])
        #expect(usual.codex == "/Users/me/.codex" && usual.openCode == "/Users/me/.local/share/opencode" && usual.gemini == "/Users/me/.gemini")
        #expect(usual.antigravityHistory == "/Users/me/.gemini/antigravity-cli/history.jsonl")
        let moved = AgentFolders(home: home, environment: ["CLAUDE_CONFIG_DIR": "~/work/claude, /Volumes/x/claude/", "CODEX_HOME": "/opt/codex",
                                                           "XDG_DATA_HOME": "~/data", "GEMINI_CLI_HOME": "/srv/g", "XDG_CONFIG_HOME": "/cfg"])
        #expect(moved.claude == ["/Users/me/work/claude", "/Volumes/x/claude"])
        #expect(moved.claudeAccounts == ["/Users/me/work/claude/.claude.json", "/Volumes/x/claude/.claude.json"])
        #expect(moved.codex == "/opt/codex" && moved.openCode == "/Users/me/data/opencode" && moved.gemini == "/srv/g/.gemini")
        #expect(AgentFolders(home: home, environment: ["XDG_CONFIG_HOME": "/cfg"]).claude == ["/cfg/claude", "/Users/me/.claude"])
        // Symlinks resolved, and the same folder once.
        let linked = AgentFolders(home: home) { $0 == "/Users/me/.config/claude" ? "/Users/me/.claude" : $0 }
        #expect(linked.claude == ["/Users/me/.claude"])
        // What a changed file is.
        #expect(usual.role(of: "/Users/me/.claude/sessions/123.json") == .claudeStatus)
        #expect(usual.role(of: "/Users/me/.claude/sessions/123.abc.key") == nil)
        #expect(usual.role(of: "/Users/me/.config/claude/projects/-dev-app/s/subagents/deep/a.jsonl") == .claudeLog)
        #expect(usual.role(of: "/Users/me/.codex/archived_sessions/rollout-1.jsonl") == .codexLog)
        #expect(usual.role(of: "/Users/me/.codex/sessions2/rollout-1.jsonl") == nil)
        #expect(usual.role(of: "/Users/me/.local/share/opencode/opencode.db-wal") == .openCodeData)
        #expect(usual.role(of: "/Users/me/.local/share/opencode/opencode-beta.db") == .openCodeData)
        #expect(usual.role(of: "/Users/me/.local/share/opencode/opencode.db-shm") == nil)
        #expect(usual.role(of: "/Users/me/.local/share/opencode/log/2026.log") == nil)
        #expect(usual.role(of: "/Users/me/.local/share/opencode/storage/message/ses_1/msg_1.json") == .openCodeData)
        #expect(usual.role(of: "/Users/me/.gemini/tmp/my-app/chats/session-2026-10-09T10-00-5f1c0000.jsonl") == .geminiChat)
        #expect(usual.role(of: "/Users/me/.gemini/tmp/my-app/chats/5f1c/sub1.jsonl") == .geminiChat)
        #expect(usual.role(of: "/Users/me/.gemini/tmp/my-app/logs.json") == nil)
        #expect(usual.role(of: "/Users/me/.gemini/antigravity-cli/history.jsonl") == .antigravityHistory)
        // Settings shows the folders that are there.
        #expect(usual.shown(.claudeCode) { $0 == "/Users/me/.claude" } == ["/Users/me/.claude"])
        #expect(usual.shown(.claudeCode) { _ in false } == ["/Users/me/.claude"])
        #expect(usual.shown(.gemini) { $0 == usual.antigravityHistory } == ["/Users/me/.gemini/antigravity-cli"])
    }

    @Test func formats() {
        let us = Locale(identifier: "en_US")
        #expect(IslandFormat.tokens(950) == "950" && IslandFormat.tokens(12_500) == "12.5K")
        #expect(IslandFormat.dollars(0.4249, locale: us) == "$0.42" && IslandFormat.dollars(12.4, locale: us) == "$12.40")
        #expect(IslandFormat.dollars(123.4, locale: us) == "$123" && IslandFormat.dollars(1234, locale: us) == "$1.2K")
        #expect(IslandFormat.dollars(0, locale: us) == "$0.00" && IslandFormat.dollars(-1, locale: us) == "$0.00")
        // In the reader's own way: a comma in Germany, "US$" in Britain.
        #expect(IslandFormat.dollars(0.4249, locale: Locale(identifier: "de_DE")).hasPrefix("0,42"))
        #expect(IslandFormat.dollars(12.4, locale: Locale(identifier: "en_GB")) == "US$12.40")
        // (With a narrow space before "PM".)
        #expect(IslandFormat.hour(18, locale: us) == "6\u{202F}PM" && IslandFormat.hour(0, locale: us) == "12\u{202F}AM")
        #expect(IslandFormat.hour(18, locale: Locale(identifier: "en_GB")) == "18")
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
