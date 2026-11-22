import Foundation

/// Whether a tile's name can be written through to its origin, and how. Every source keeps its own
/// title: a rename either lands in the origin's store, is typed into the agent's own `/rename`,
/// or is refused with a source-specific reason. See notes/title-origin-design.md.
public enum RenameSupport: Equatable, Sendable {
    public enum Mechanism: String, Equatable, Sendable {
        /// Tessera owns the title (custom shells, browsers): it is applied at once.
        case tessera
        /// Typed `/rename <name>` at the agent's idle prompt, through the wake pipeline.
        case typed
        /// `codex app-server` JSON-RPC `thread/name/set`, for Codex terminals and app threads.
        case codexAppServer
    }

    case supported(Mechanism)
    case unsupported(String)

    /// How a rename would happen, or nil when this source can't be renamed.
    public var mechanism: Mechanism? {
        if case .supported(let mechanism) = self { return mechanism }
        return nil
    }

    /// The answer for one tile: its kind and flavor, whether the agent is actually running in the
    /// foreground, and the bound session id when one is known.
    public static func support(kind: TileKind, flavor: AgentFlavor, agentRunning: Bool,
                               sessionId: String?) -> RenameSupport {
        func refuse(_ why: String) -> RenameSupport { .unsupported("This source can't be renamed: \(why).") }
        switch kind {
        case .browser:
            return .supported(.tessera)
        case .terminal:
            switch flavor {
            case .shell, .custom, .web:
                return .supported(.tessera)
            case .claude:
                return agentRunning ? .supported(.typed)
                    : refuse("Claude Code isn't running in this tile")
            case .codex:
                return sessionId != nil ? .supported(.codexAppServer)
                    : refuse("Codex has no bound conversation in this tile yet")
            case .devin:
                return agentRunning ? .supported(.typed)
                    : refuse("Devin isn't running in this tile")
            case .omp:
                return agentRunning ? .supported(.typed)
                    : refuse("omp isn't running in this tile")
            case .antigravity:
                return agentRunning ? .supported(.typed)
                    : refuse("Antigravity isn't running in this tile")
            case .grok, .gemini, .opencode, .aider, .dsh:
                return refuse("\(flavor.displayName) sessions have no supported rename")
            case .claudeDesktop, .codexDesktop, .zcodeDesktop, .antigravityDesktop:
                return refuse("\(flavor.displayName) sessions have no supported rename")
            case .lloom, .agentDesk, .accord:
                return refuse("\(flavor.displayName) tiles have no supported rename")
            }
        case .agentSession:
            switch flavor {
            case .codexDesktop:
                return sessionId != nil ? .supported(.codexAppServer)
                    : refuse("Codex has no bound conversation in this tile yet")
            case .claudeDesktop:
                return refuse("Claude app conversations have no supported way to rename them")
            case .zcodeDesktop:
                return refuse("Enntity ZCode sessions can't be renamed yet")
            case .antigravityDesktop:
                return refuse("Antigravity app conversations have no supported way to rename them")
            default:
                return refuse("\(flavor.displayName) sessions have no supported rename")
            }
        }
    }

    /// One line of at most 120 characters with no control characters, trimmed; nil when nothing
    /// usable is left. Applied to anything typed into an agent or sent over app-server.
    public static func sanitizedName(_ name: String, limit: Int = 120) -> String? {
        var out = ""
        for scalar in name.unicodeScalars {
            guard scalar != "\n", scalar != "\r" else { break }
            if !CharacterSet.controlCharacters.contains(scalar) { out.unicodeScalars.append(scalar) }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
