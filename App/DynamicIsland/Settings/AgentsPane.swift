import IslandCore
import SwiftUI

/// Settings › AI Agents: which agents, which card on the dashboard (each one
/// live, with your own numbers), and the island while they work.
struct AgentsPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var store = env.settings
        let s = store.settings
        let enabled = s[module: .agents].enabled
        Form {
            Section {
                Toggle(isOn: $store.settings[module: .agents].enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show AI agents")
                        Text("Claude Code, Codex, OpenCode and Gemini: what they're doing, how much they've used, and when they finish. Read from the files they keep on this Mac: only counts, times and folders, never what was said, and nothing is sent anywhere.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Group {
                Section {
                    AgentCardPicker()
                    DashboardPlacement()
                } header: {
                    Text("Dashboard card")
                } footer: {
                    Text(s.agents.card.summary)
                }
                Section {
                    Toggle(isOn: $store.settings.agents.showCost) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show what it costs")
                            Text("At Anthropic's and OpenAI's API prices for each model, cache and fast mode included; OpenCode's own figures. With a subscription such as Claude Max you don't pay per token, so it's what the same work would cost through the API. Models running on this Mac are free.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cost")
                }
                Section {
                    ForEach(AgentKind.allCases) { AgentRow(agent: $0) }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Agents join when the files they keep are found. Gemini keeps its token counts in a format the island can't read, so it shows prompts and sessions. Claude Code doesn't keep its plan's percentage on the Mac, so its card shows the 5-hour window's timing and the tokens used.")
                }
                Section {
                    Toggle(isOn: $store.settings.agents.showWorking) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show agents while they work")
                            Text("Their badge, a spinner and how long it's been going, beside the camera, even when the island shows on hover. Click it for every open session.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $store.settings.agents.alertWhenDone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alert when one finishes")
                            Text("Which agent, which project and how long it took, when it stops and waits for you. Click it to go back.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Only after working for", selection: $store.settings.agents.alertMinimumSeconds) {
                        Text("Any length").tag(0.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                    }
                    .disabled(!s.agents.alertWhenDone)
                    HStack {
                        Button("Show a Sample Alert") {
                            env.engine.post(IslandAlert(kind: .agents, style: .agentFinished(
                                AgentFinish(id: UUID().uuidString, session: "", agent: .claudeCode, project: "dynamic_island", duration: 400)), holdSeconds: 5))
                        }
                        Text("Shows one on the island itself.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On the island")
                }
            }
            .disabled(!enabled)
        }
    }
}

/// The four cards, each live with your own numbers: click one to use it.
private struct AgentCardPicker: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: IslandViewModel?

    var body: some View {
        let chosen = env.settings.settings.agents.card
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            if let model {
                ForEach(AgentCardStyle.allCases) { style in
                    Button { env.settings.settings.agents.card = style } label: {
                        VStack(spacing: 6) {
                            IslandCard(title: style.cardTitle, symbol: DashboardWidgetKind.agents.symbolName, radius: 16) {
                                AgentsWidget(size: .medium, model: model, style: style)
                            }
                            .frame(height: DashboardLayout.cardHeight)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(style == chosen ? Color.accentColor : .clear, lineWidth: 3)
                            }
                            .environment(\.colorScheme, .dark)
                            HStack(spacing: 5) {
                                Image(systemName: style == chosen ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(style == chosen ? Color.accentColor : .secondary)
                                Text(style.displayName).font(.callout.weight(style == chosen ? .semibold : .regular))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(style == chosen ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if model == nil {
                let m = IslandViewModel(env: env, notch: NotchRect(rect: CGRect(x: 0, y: 0, width: 185, height: 32), isHardware: false))
                m.forced = .dashboard
                model = m
            }
        }
    }
}

/// Whether the card is on the dashboard, and within its three rows.
private struct DashboardPlacement: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let s = env.settings.settings
        let onDashboard = s.dashboard.contains { $0.kind == .agents }
        let fits = DashboardLayout.rows(s.visibleDashboard, columns: s.dashboardColumns).joined().contains { $0.kind == .agents }
        LabeledContent("On the dashboard") {
            if !onDashboard {
                Button("Add to Dashboard") {
                    withAnimation { env.settings.settings.dashboard.append(DashboardItem(.agents, .medium)) }
                }
            } else if fits {
                Text("Yes").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Past the dashboard's three rows").foregroundStyle(.orange)
                    Button("Arrange…") { UserDefaults.standard.set(SettingsPane.dashboard.rawValue, forKey: "settings.lastPane") }
                }
            }
        }
    }
}

/// An agent: whether it's on this Mac, when it was last used, and its switch.
private struct AgentRow: View {
    let agent: AgentKind
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let agents = env.agents
        let installed = agents.installed.contains(agent)
        Toggle(isOn: Binding(get: { installed && env.settings.settings.agents.isOn(agent) },
                             set: { env.settings.settings.agents.agents[agent.rawValue] = $0 })) {
            HStack(spacing: 10) {
                AgentBadge(agent: agent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName)
                    Text(status(installed: installed)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!installed)
    }

    private func status(installed: Bool) -> String {
        guard installed else { return "Not on this Mac (~/\(agent.folder))" }
        let week = env.agents.ledger.week(agent, now: .now)
        let cost = env.settings.settings.agents.showCost && week.cost > 0 ? " · \(IslandFormat.dollars(week.cost)) this week" : ""
        let open = env.agents.sessions.filter { $0.agent == agent }
        if !open.isEmpty {
            let working = open.filter { $0.state == .working }.count
            return (working > 0 ? "\(working) working now" : "\(open.count) open, waiting for you") + cost
        }
        if let last = env.agents.ledger.lastUsed[agent] {
            return "Last used \(last.formatted(.relative(presentation: .named)))\(cost)"
        }
        return env.agents.loaded ? "On this Mac, not used this week" : "On this Mac"
    }
}
