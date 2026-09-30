import Foundation

/// What a tile hosts. The host owns the underlying thing; clients only see `TileInfo`.
public enum TileKind: String, Codable, Sendable {
    case terminal
    case agentSession   // a conversation living inside a desktop app (Claude, Codex)
    case browser
}

/// Which tool a tile belongs to. Drives accent color, glyph, and prompt heuristics.
public enum AgentFlavor: String, Codable, Sendable, CaseIterable {
    case shell, claude, codex, grok, gemini, omp, opencode, aider, custom
    case claudeDesktop, codexDesktop
    /// DeepSeek Harness (`dsh`) sessions.
    case dsh
    case web

    public var displayName: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .omp: "omp"
        case .opencode: "opencode"
        case .aider: "aider"
        case .custom: "Command"
        case .claudeDesktop: "Claude"
        case .codexDesktop: "Codex"
        case .dsh: "DeepSeek"
        case .web: "Web"
        }
    }

    /// SF Symbol used on tiles and in the launcher.
    public var symbol: String {
        switch self {
        case .shell: "terminal"
        case .claude, .claudeDesktop: "sparkle"
        case .codex, .codexDesktop: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.horizontal"
        case .gemini: "diamond"
        case .omp: "circle.hexagongrid"
        case .opencode: "curlybraces"
        case .aider: "wand.and.stars"
        case .custom: "gearshape.2"
        case .dsh: "water.waves"
        case .web: "globe"
        }
    }

    /// Guess the flavor from a command line (`claude --resume x` → .claude).
    public static func infer(fromCommand command: String?) -> AgentFlavor {
        guard let command, let first = command.split(separator: " ").first.map(String.init) else { return .shell }
        // Launchers (`codex-work`) look like their tool.
        switch SessionResume.tool(for: command) {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .opencode: return .opencode
        case .omp: return .omp
        case nil: break
        }
        let exe = (first as NSString).lastPathComponent.lowercased()
        switch exe {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        case "gemini": return .gemini
        case "omp": return .omp
        case "opencode": return .opencode
        case "aider": return .aider
        case "dsh": return .dsh
        case "zsh", "bash", "fish", "sh": return .shell
        default: return .custom
        }
    }
}

/// The one state vocabulary every tile type maps into.
public enum TileActivity: String, Codable, Sendable {
    case starting, working, idle, done, needsInput, exited, failed

    /// States that should pull the user's eye until acknowledged.
    public var isAttention: Bool { self == .done || self == .needsInput || self == .failed }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .idle: "Idle"
        case .done: "Done"
        case .needsInput: "Needs you"
        case .exited: "Exited"
        case .failed: "Failed"
        }
    }
}

public struct TileInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: TileKind
    public var flavor: AgentFlavor
    public var title: String
    /// cwd, URL host, or project — the second line on a card.
    public var subtitle: String
    public var activity: TileActivity
    /// Attention the user has not yet acknowledged by opening the tile.
    public var attention: Bool
    public var lastActivityAt: Date
    /// One-line status such as "Waiting on Bash approval" or a turn summary.
    public var detail: String?
    public var cols: Int?
    public var rows: Int?
    public var url: String?
    /// 0...1 when the program reports progress (OSC 9;4).
    public var progress: Double?

    /// Attention in a state that still wants the user; a tile that went back to work has moved on.
    public var isUnseen: Bool { attention && activity.isAttention }
    /// Waiting on the user: an open question or an unseen result.
    public var needsUser: Bool { isUnseen || activity == .needsInput }

    public init(id: String, kind: TileKind, flavor: AgentFlavor, title: String, subtitle: String = "",
                activity: TileActivity = .starting, attention: Bool = false, lastActivityAt: Date = Date(),
                detail: String? = nil, cols: Int? = nil, rows: Int? = nil, url: String? = nil, progress: Double? = nil) {
        self.id = id
        self.kind = kind
        self.flavor = flavor
        self.title = title
        self.subtitle = subtitle
        self.activity = activity
        self.attention = attention
        self.lastActivityAt = lastActivityAt
        self.detail = detail
        self.cols = cols
        self.rows = rows
        self.url = url
        self.progress = progress
    }
}

/// Which tiles are working, waiting on the user, or holding an unseen result. The Mac keeps this
/// current as tiles change, so the HUD and tabs don't depend on every tile's data.
public struct BoardState: Equatable, Sendable {
    public var working: Set<String> = []
    public var needsInput: Set<String> = []
    /// Unseen results and questions (`TileInfo.isUnseen`).
    public var unseen: Set<String> = []

    public init(_ tiles: [TileInfo] = []) {
        for tile in tiles {
            if tile.activity == .working { working.insert(tile.id) }
            if tile.activity == .needsInput { needsInput.insert(tile.id) }
            if tile.isUnseen { unseen.insert(tile.id) }
        }
    }

    /// Everything waiting on the user (`TileInfo.needsUser`).
    public var needsUser: Set<String> { needsInput.union(unseen) }
    /// Unseen results that aren't questions.
    public var done: Int { unseen.subtracting(needsInput).count }
}

public struct ConversationItem: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool, toolResult, thinking, system }
    public var id: String
    public var role: Role
    public var text: String
    public var toolName: String?
    public var isError: Bool
    public var timestamp: Date?

    public init(id: String, role: Role, text: String, toolName: String? = nil, isError: Bool = false, timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.isError = isError
        self.timestamp = timestamp
    }
}

/// A live, trimmed view of a desktop-app conversation.
public struct ConversationSnapshot: Codable, Hashable, Sendable {
    public var items: [ConversationItem]
    public var activity: TileActivity
    public var detail: String?
    public var model: String?
    public var lastEventAt: Date?
    public var contextTokens: Int?

    public init(items: [ConversationItem] = [], activity: TileActivity = .idle, detail: String? = nil,
                model: String? = nil, lastEventAt: Date? = nil, contextTokens: Int? = nil) {
        self.items = items
        self.activity = activity
        self.detail = detail
        self.model = model
        self.lastEventAt = lastEventAt
        self.contextTokens = contextTokens
    }
}

public extension String {
    /// Single-line, bounded preview text for cards.
    func preview(_ limit: Int) -> String {
        let flat = split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    /// A one-line preview with inline Markdown rendered (bold, italics, `code`, links) and block
    /// syntax like headings and list bullets dropped, for cards.
    func markdownPreview(_ limit: Int) -> AttributedString {
        let flat = split(whereSeparator: \.isNewline)
            .map { line -> Substring in
                var l = line.drop(while: { $0 == " " })
                while l.first == "#" { l = l.dropFirst() }
                if l.hasPrefix("- ") || l.hasPrefix("* ") { l = l.dropFirst(2) }
                return l.drop(while: { $0 == " " })
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let text = flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// `/Users/me/src/app` → `~/src/app`.
    var abbreviatingHome: String {
        hasPrefix(homeDirectory) ? "~" + dropFirst(homeDirectory.count) : self
    }
}

private let homeDirectory = NSHomeDirectory()
