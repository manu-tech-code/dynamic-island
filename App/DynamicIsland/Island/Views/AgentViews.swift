import IslandCore
import SwiftUI

extension AgentKind {
    var color: Color {
        Color(red: Double((colorHex >> 16) & 0xFF) / 255, green: Double((colorHex >> 8) & 0xFF) / 255, blue: Double(colorHex & 0xFF) / 255)
    }
}

/// An agent's badge: its letters on its colour.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(agent.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(agent.letter)
                    .font(.system(size: size * (agent.letter.count > 1 ? 0.42 : 0.56), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(agent.displayName)
    }
}

/// A spinning arc in the agent's colour, turned by Core Animation: a SwiftUI
/// animation would redraw the whole island every frame.
struct AgentSpinner: View {
    let agent: AgentKind
    var size: CGFloat = 13
    var moving = true
    @State private var image: CGImage?

    private static var pictures: [String: CGImage] = [:]

    var body: some View {
        LayerAnimatedImage(image: image, motion: .spin(period: 0.9), moving: moving)
            .frame(width: size, height: size)
            .onAppear { image = Self.picture(agent, size) }
            .onChange(of: agent) { _, a in image = Self.picture(a, size) }
            .accessibilityHidden(true)
    }

    private static func picture(_ agent: AgentKind, _ size: CGFloat) -> CGImage? {
        let key = "\(agent.rawValue)-\(size)"
        if let hit = pictures[key] { return hit }
        let arc = ZStack {
            Circle().inset(by: 1).stroke(agent.color.opacity(0.3), lineWidth: 2)
            Circle().inset(by: 1).trim(from: 0, to: 0.28).stroke(agent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: size, height: size)
        let image = LayerPicture.render(arc)
        pictures[key] = image
        return image
    }
}

/// A small green dot: working now.
struct LiveDot: View {
    var body: some View {
        Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Working")
    }
}

extension Array where Element == AgentSession {
    /// Each agent once, in order.
    var agents: [AgentKind] { reduce(into: []) { if !$0.contains($1.agent) { $0.append($1.agent) } } }
}

// MARK: compact island

/// Agents at work: their badges and a spinner beside the camera…
struct AgentsLeading: View {
    let sessions: [AgentSession]
    let model: IslandViewModel

    var body: some View {
        let agents = sessions.agents
        HStack(spacing: IslandMetrics.glyphSpacing) {
            ForEach(agents.prefix(2), id: \.self) { a in
                AgentBadge(agent: a, size: IslandMetrics.glyph - 2).frame(width: IslandMetrics.glyph, height: IslandMetrics.glyph)
            }
            if let first = agents.first {
                AgentSpinner(agent: first, size: 13, moving: !model.reduceMotion && !model.isTucked)
                    .frame(width: IslandMetrics.agentSpinner)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessions.count == 1 ? "\(sessions[0].agent.displayName) working in \(sessions[0].project)" : "\(sessions.count) agents working")
    }
}

/// …and how long the longest at work has been going, on the other side.
struct AgentsElapsed: View {
    let sessions: [AgentSession]

    var body: some View {
        if let first = sessions.first {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(IslandFormat.elapsed(ctx.date.timeIntervalSince(first.since)))
                    .monospacedDigit()
                    .foregroundStyle(first.agent.color)
            }
        }
    }
}

/// Below the notch: badge, spinner, project, and the clock.
struct AgentsBand: View {
    let sessions: [AgentSession]
    let model: IslandViewModel

    var body: some View {
        if let first = sessions.first {
            AgentsLeading(sessions: sessions, model: model)
            Text(sessions.count == 1 ? first.project : "\(first.project) +\(sessions.count - 1)").lineLimit(1)
            Spacer(minLength: 4)
            AgentsElapsed(sessions: sessions)
        }
    }
}

// MARK: open

/// The agents' sessions open now (a click on the compact island): each one's
/// project and state; click to bring its app or terminal forward.
struct AgentsExpanded: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sessions = env.agents.sessions
        let working = sessions.filter { $0.state == .working }.count
        VStack(spacing: 0) {
            EarRow(model: model) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.orange)
                        Text("AI agents").fixedSize()
                    }
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                }
            } trailing: {
                if working > 0 { Text("\(working) working").foregroundStyle(.secondary).fixedSize() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(sessions) { s in AgentSessionRow(session: s, model: model, compact: false) }
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }
}

/// One open session. Click to bring its app or terminal forward.
struct AgentSessionRow: View {
    let session: AgentSession
    let model: IslandViewModel
    var compact = true
    /// A small card: "Waiting · 3 m".
    var short = false
    @Environment(AppEnvironment.self) private var env
    @State private var hovering = false

    var body: some View {
        Button {
            env.agents.bringForward(session)
            if !model.isPreview { model.collapse() }
        } label: {
            HStack(spacing: compact ? 7 : 10) {
                AgentBadge(agent: session.agent, size: compact ? 16 : 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.project).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: session.state == .working ? 1 : 60)) { ctx in
                        Text(state(at: ctx.date))
                            .font(.system(size: compact ? 10.5 : 11.5))
                            .foregroundStyle(session.state == .working ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !compact { Text(session.agent.displayName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 3 : 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.pid == nil ? session.folder : "Bring \(session.agent.displayName) forward")
    }

    private func state(at now: Date) -> String {
        let gone = now.timeIntervalSince(session.since)
        switch session.state {
        case .working: return "Working · \(IslandFormat.elapsed(gone))"
        case .waiting:
            let waiting = short ? "Waiting" : "Waiting for you"
            return gone < 60 ? waiting : "\(waiting) · \(IslandFormat.took(gone).replacingOccurrences(of: #" \d+ s$"#, with: "", options: .regularExpression))"
        }
    }
}

// MARK: dashboard

/// The dashboard's AI Agents card, in the style chosen in Settings › AI Agents.
/// The week's usage is read while it shows.
struct AgentsWidget: View {
    let size: WidgetSize
    let model: IslandViewModel
    /// Settings' previews show each style; the dashboard shows the chosen one.
    var style: AgentCardStyle?
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        content
            .onAppear { env.agents.acquire() }
            .onDisappear { env.agents.release() }
    }

    @ViewBuilder private var content: some View {
        let agents = env.agents
        let card = style ?? model.settings.agents.card
        if agents.shown.isEmpty {
            AgentsPlaceholder(text: agents.installed.isEmpty ? "No AI agents on this Mac yet" : "Choose agents in Settings")
        } else if card != .running, !agents.loaded {
            AgentsPlaceholder(text: "Reading your agents' logs…", progress: true)
        } else {
            TimelineView(.everyMinute) { ctx in
                switch card {
                case .agents: AgentsOverviewCard(size: size, now: ctx.date)
                case .window: AgentWindowCard(size: size, now: ctx.date)
                case .today: AgentsTodayCard(size: size, now: ctx.date)
                case .running: AgentsRunningCard(size: size, model: model)
                }
            }
        }
    }
}

private struct AgentsPlaceholder: View {
    let text: String
    var progress = false

    var body: some View {
        VStack(spacing: 6) {
            if progress { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The agents shown, the most recently used first.
@MainActor private func shownAgents(_ env: AppEnvironment) -> [AgentKind] {
    let a = env.agents
    return AgentKind.allCases.filter { a.shown.contains($0) }
        .sorted { (a.ledger.lastUsed[$0] ?? .distantPast) > (a.ledger.lastUsed[$1] ?? .distantPast) }
}

/// A · a row per agent, and Claude's window underneath.
private struct AgentsOverviewCard: View {
    let size: WidgetSize
    let now: Date
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let agents = env.agents
        let window = agents.shown.contains(.claudeCode) ? agents.ledger.window(now: now) : nil
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shownAgents(env).prefix(window == nil ? 4 : 3), id: \.self) { a in
                let working = agents.sessions.filter { $0.agent == a && $0.state == .working }.count
                HStack(spacing: 6) {
                    AgentBadge(agent: a, size: 15)
                    if size == .medium { Text(a.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize() }
                    Text(detail(a)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    if working > 0 {
                        LiveDot()
                        if size == .medium { Text("\(working) working").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green).fixedSize() }
                    }
                }
            }
            Spacer(minLength: 0)
            if let window {
                HStack {
                    Text("\(size == .small ? "Resets" : "Claude window resets") \(window.resets.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(IslandFormat.took(window.left(now: now)).replacingOccurrences(of: #" \d+ s$"#, with: "", options: .regularExpression))
                        .fontWeight(.semibold).lineLimit(1).fixedSize()
                }
                .font(.system(size: 10.5))
                MeterBar(fraction: window.fraction(now: now), color: AgentKind.claudeCode.color)
            } else if let limit = agents.ledger.limits[.codex], agents.shown.contains(.codex) {
                HStack {
                    Text("Codex limit").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(limit.usedPercent.rounded()))% used").fontWeight(.semibold)
                }
                .font(.system(size: 10.5))
                MeterBar(fraction: limit.usedPercent / 100, color: AgentKind.codex.color)
            }
        }
    }

    /// Today's work, or the week's when it's been quiet today.
    private func detail(_ a: AgentKind) -> String {
        let ledger = env.agents.ledger
        let today = ledger.today(a, now: now)
        let medium = size == .medium
        if today.replies > 0 {
            if !a.countsTokens { return "\(today.replies) prompt\(today.replies == 1 ? "" : "s") today" }
            return medium ? "\(today.replies.formatted()) replies · \(IslandFormat.tokens(today.tokens)) tokens" : "\(IslandFormat.tokens(today.tokens)) today"
        }
        let week = ledger.week(a, now: now)
        if week.sessions > 0 { return medium ? "\(week.sessions) session\(week.sessions == 1 ? "" : "s") this week" : "\(week.sessions) this week" }
        return medium ? "Nothing this week" : "Quiet"
    }
}

/// B · Claude Code's 5-hour window as a ring.
private struct AgentWindowCard: View {
    let size: WidgetSize
    let now: Date
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let agents = env.agents
        let window = agents.ledger.window(now: now)
        let ringSize: CGFloat = size == .small ? 72 : 90
        let ring = ZStack {
            Ring(fraction: window?.fraction(now: now) ?? 0, color: AgentKind.claudeCode.color, lineWidth: 6)
            VStack(spacing: 0) {
                Text(window.map { IslandFormat.elapsed($0.left(now: now)).replacingOccurrences(of: "h ", with: ":") } ?? "–")
                    .font(.system(size: size == .small ? 17 : 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(window == nil ? "no window" : "left").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .frame(width: ringSize, height: ringSize)
        if !agents.shown.contains(.claudeCode) {
            AgentsPlaceholder(text: "Claude Code isn't on this Mac, or is switched off")
        } else if size == .small {
            VStack(spacing: 6) {
                ring
                Text(window.map { "Resets \($0.resets.formatted(date: .omitted, time: .shortened))" } ?? "Opens with your next message")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let today = agents.ledger.today(.claudeCode, now: now)
            let running = agents.sessions.filter { $0.agent == .claudeCode && $0.state == .working }.count
            HStack(spacing: 14) {
                ring
                VStack(alignment: .leading, spacing: 5) {
                    stat(window.map { IslandFormat.tokens($0.tokens) } ?? "0",
                         window.map { "tokens this window · resets \($0.resets.formatted(date: .omitted, time: .shortened))" } ?? "tokens · no window open")
                    stat(today.replies.formatted(), "replies today · \(IslandFormat.tokens(today.output)) written")
                    HStack(spacing: 5) {
                        if running > 0 { LiveDot() }
                        Text(running == 0 ? "Nothing running" : "\(running) session\(running == 1 ? "" : "s") working")
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(running > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func stat(_ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// C · today, hour by hour.
private struct AgentsTodayCard: View {
    let size: WidgetSize
    let now: Date
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let ledger = env.agents.ledger
        let agents = shownAgents(env).filter(\.countsTokens)
        let days = agents.map { ($0, ledger.today($0, now: now)) }
        let total = days.reduce(0) { $0 + $1.1.tokens }
        let sessions = days.reduce(0) { $0 + $1.1.sessions.count }
        VStack(alignment: .leading, spacing: 6) {
            if size == .small {
                VStack(alignment: .leading, spacing: 0) {
                    Text(IslandFormat.tokens(total)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("tokens · \(sessions) session\(sessions == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(days.filter { $0.1.tokens > 0 }.prefix(3), id: \.0) { a, day in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(IslandFormat.tokens(day.tokens)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(a.color).frame(width: 8, height: 8)
                                Text(a.displayName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    if total == 0 { Text("Nothing yet today").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
            HourBars(days: days, hour: Calendar.current.component(.hour, from: now), height: size == .small ? 44 : 50)
            if size == .medium {
                HStack {
                    ForEach(["0:00", "6:00", "12:00", "18:00", "23:00"], id: \.self) { t in
                        Text(t)
                        if t != "23:00" { Spacer(minLength: 0) }
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A bar per hour, each agent's share in its colour; the hour now outlined.
private struct HourBars: View {
    let days: [(AgentKind, AgentDay)]
    let hour: Int
    let height: CGFloat

    var body: some View {
        let totals = (0..<24).map { h in days.reduce(0) { $0 + $1.1.hours[h] } }
        let peak = max(1, totals.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<24, id: \.self) { h in
                VStack(spacing: 0) {
                    ForEach(days.reversed(), id: \.0) { a, day in
                        if day.hours[h] > 0 {
                            Rectangle().fill(a.color).frame(height: max(1, height * CGFloat(day.hours[h]) / CGFloat(peak)))
                        }
                    }
                    if totals[h] == 0 { Rectangle().fill(.primary.opacity(0.12)).frame(height: 2) }
                }
                .frame(maxWidth: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5))
                .overlay(alignment: .bottom) {
                    if h == hour {
                        RoundedRectangle(cornerRadius: 2).stroke(.primary.opacity(0.55), lineWidth: 1)
                            .frame(height: max(6, height * CGFloat(totals[h]) / CGFloat(peak)))
                    }
                }
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per hour today")
    }
}

/// D · the sessions open now.
private struct AgentsRunningCard: View {
    let size: WidgetSize
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sessions = env.agents.sessions
        if sessions.isEmpty {
            AgentsPlaceholder(text: "Nothing running. Sessions show here while they're open.")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(sessions.prefix(3)) { s in AgentSessionRow(session: s, model: model, compact: true, short: size == .small) }
                if sessions.count > 3 {
                    Text("+\(sessions.count - 3) more").font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            .padding(.horizontal, -6)
            Spacer(minLength: 0)
        }
    }
}
