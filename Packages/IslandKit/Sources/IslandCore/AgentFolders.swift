import Foundation

/// Where each agent keeps its files: the usual folders, or where the variables
/// your shell profile sets move them. Folders are given with symlinks resolved,
/// as file-change events name them.
public struct AgentFolders: Equatable, Sendable {
    /// The variables that move them.
    public static let variables = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "GEMINI_CLI_HOME"]

    /// Claude Code's folders, each with projects/ (logs) and sessions/ (status files):
    /// CLAUDE_CONFIG_DIR's (a list, split by commas), or ~/.config/claude and ~/.claude.
    public var claude: [String]
    /// Claude Code's settings files, which say whether it's signed in to a Claude plan.
    public var claudeAccounts: [String]
    /// CODEX_HOME, or ~/.codex.
    public var codex: String
    /// XDG_DATA_HOME/opencode, or ~/.local/share/opencode.
    public var openCode: String
    /// Gemini CLI's .gemini folder: in GEMINI_CLI_HOME, or the home folder.
    public var gemini: String
    /// Antigravity CLI's prompt history.
    public var antigravityHistory: String

    /// - Parameter resolve: resolves symlinks (realpath); the folder as it is when it doesn't exist.
    public init(home: String, environment: [String: String] = [:], resolve: (String) -> String = { $0 }) {
        func path(_ s: String) -> String {
            var p = s.trimmingCharacters(in: .whitespaces)
            if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst() }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        func variable(_ name: String) -> String? {
            environment[name].map(path).flatMap { $0.isEmpty ? nil : $0 }
        }
        var claude: [String]
        if let dirs = environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").map({ path(String($0)) }).filter({ !$0.isEmpty }), !dirs.isEmpty {
            claude = dirs
            claudeAccounts = dirs.map { $0 + "/.claude.json" }
        } else {
            claude = [(variable("XDG_CONFIG_HOME") ?? home + "/.config") + "/claude", home + "/.claude"]
            claudeAccounts = [home + "/.claude.json"]
        }
        claude = claude.map(resolve).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        self.claude = claude
        codex = resolve(variable("CODEX_HOME") ?? home + "/.codex")
        openCode = resolve((variable("XDG_DATA_HOME") ?? home + "/.local/share") + "/opencode")
        gemini = resolve((variable("GEMINI_CLI_HOME") ?? home) + "/.gemini")
        antigravityHistory = resolve(home + "/.gemini/antigravity-cli") + "/history.jsonl"
    }

    public var claudeProjects: [String] { claude.map { $0 + "/projects" } }
    public var claudeSessions: [String] { claude.map { $0 + "/sessions" } }
    /// Running sessions' logs, then archived ones'.
    public var codexSessions: [String] { [codex + "/sessions", codex + "/archived_sessions"] }
    /// Gemini CLI's chats are in tmp/<project>/chats.
    public var geminiProjects: String { gemini + "/tmp" }

    /// What a file is to the island, from its path.
    public enum Role: Equatable, Sendable {
        case claudeStatus, claudeLog, codexLog, openCodeData, geminiChat, antigravityHistory
    }

    public func role(of path: String) -> Role? {
        func inside(_ folder: String) -> Bool { path.hasPrefix(folder + "/") }
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        if claudeSessions.contains(where: inside), name.hasSuffix(".json") { return .claudeStatus }
        if claudeProjects.contains(where: inside), name.hasSuffix(".jsonl") { return .claudeLog }
        if codexSessions.contains(where: inside), name.hasSuffix(".jsonl") { return .codexLog }
        if path == antigravityHistory { return .antigravityHistory }
        if inside(geminiProjects), path.contains("/chats/"), name.hasSuffix(".jsonl") || name.hasSuffix(".json") { return .geminiChat }
        if inside(openCode) {
            // Its databases (opencode.db, a preview's opencode-<channel>.db) and what's
            // written ahead of them; or a message, before version 1.2. Not its logs or snapshots.
            if name.hasPrefix("opencode"), name.hasSuffix(".db") || name.hasSuffix(".db-wal") { return .openCodeData }
            if inside(openCode + "/storage/message"), name.hasSuffix(".json") { return .openCodeData }
        }
        return nil
    }

    /// The folders an agent's files are read from, for Settings: the ones
    /// that are there, or where they'd usually be.
    public func shown(_ agent: AgentKind, exists: (String) -> Bool) -> [String] {
        // Each folder, and what in it shows the agent uses it.
        let (candidates, usual): ([(String, String)], String) = switch agent {
        case .claudeCode: (claude.map { ($0, $0) }, claude[claude.count - 1])
        case .codex: ([(codex, codex)], codex)
        case .openCode: ([(openCode, openCode)], openCode)
        case .gemini: ([(gemini, geminiProjects), ((antigravityHistory as NSString).deletingLastPathComponent, antigravityHistory)], gemini)
        }
        let found = candidates.filter { exists($0.1) }.map(\.0)
        return found.isEmpty ? [usual] : found
    }
}
