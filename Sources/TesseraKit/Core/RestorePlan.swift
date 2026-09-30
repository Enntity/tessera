import Foundation

/// Decides how each saved terminal comes back so that no two tiles ever attach to the same
/// conversation.
///
/// - A session id belongs to one tile: the first keeps it, any duplicate starts fresh.
/// - Tools whose sessions Tessera can bind exactly (Claude Code, Codex) never fall back to
///   "continue the latest": an unbound tile means no conversation was recorded, and "latest" could
///   be another tile's.
/// - Other tools (Grok via launchers, opencode, omp) may continue their latest session only when no
///   other tile runs that tool in the same folder.
public enum RestorePlan {
    public struct Tile: Sendable {
        public var id: String
        public var command: String?
        public var cwd: String
        public var sessionId: String?
        public init(id: String, command: String?, cwd: String, sessionId: String?) {
            self.id = id
            self.command = command
            self.cwd = cwd
            self.sessionId = sessionId
        }
    }

    public struct Decision: Equatable, Sendable {
        public var sessionId: String?
        public var mayContinueLatest: Bool
        public init(sessionId: String?, mayContinueLatest: Bool) {
            self.sessionId = sessionId
            self.mayContinueLatest = mayContinueLatest
        }
    }

    public static func plan(_ tiles: [Tile]) -> [String: Decision] {
        func key(_ t: Tile) -> String? {
            guard let command = t.command, let tool = SessionResume.tool(for: command) else { return nil }
            return tool.rawValue + "@" + t.cwd.standardizedPath
        }
        var perFolder: [String: Int] = [:]
        for t in tiles { if let k = key(t) { perFolder[k, default: 0] += 1 } }

        var used: Set<String> = []
        var out: [String: Decision] = [:]
        for t in tiles {
            var id = t.sessionId ?? t.command.flatMap(SessionResume.sessionId(in:))
            if let existing = id, !used.insert(existing).inserted { id = nil }
            var mayContinue = false
            if id == nil, let command = t.command, let tool = SessionResume.tool(for: command), let k = key(t) {
                mayContinue = !bindable(tool) && perFolder[k] == 1
            }
            out[t.id] = Decision(sessionId: id, mayContinueLatest: mayContinue)
        }
        return out
    }

    /// Tools whose conversations Tessera matches to tiles from their own session files.
    public static func bindable(_ tool: SessionResume.Tool) -> Bool {
        tool == .claude || tool == .codex
    }
}

public extension SessionResume {
    /// Commands that deliberately pick up the latest conversation (`claude -c`, `codex resume --last`).
    static func continuesLatest(_ command: String) -> Bool {
        guard let inv = Invocation(command), let tool = tool(named: inv.name) else { return false }
        let words = inv.words.dropFirst()
        switch tool {
        case .claude, .grok, .opencode, .omp: return words.contains("-c") || words.contains("--continue")
        case .codex: return words.first == "resume" && words.contains("--last")
        }
    }
}
