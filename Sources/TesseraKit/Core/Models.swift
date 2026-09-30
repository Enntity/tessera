import Foundation

/// What a tile hosts. The host owns the underlying thing; clients only see `TileInfo`.
public enum TileKind: String, Codable, Sendable {
    case terminal
    case agentSession   // a conversation living inside a desktop app (Claude, Codex)
    case browser

    /// Closing an app conversation only hides its tile (nothing is stopped), so it reads and looks
    /// different from closing a terminal or page.
    public var closeLabel: String { self == .agentSession ? "Hide" : "Close" }
    public var closeSymbol: String { self == .agentSession ? "eye.slash" : "xmark" }
    /// What the Undo toast says was done.
    public var closedLabel: String { self == .agentSession ? "Hid" : "Closed" }
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

// The Mac and the phone are updated separately, so a newer peer may send a flavor or state this
// build doesn't know: it reads as the generic case instead of failing the whole message.
public extension AgentFlavor {
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .custom
    }
}

public extension TileActivity {
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
}

/// The one state vocabulary every tile type maps into.
public enum TileActivity: String, Codable, Sendable {
    case starting, working, idle, done, needsInput, exited, failed

    /// The states that pull the user's eye until acknowledged, most pressing first: a question, a
    /// failure, a finished result.
    public static let attentionOrder: [TileActivity] = [.needsInput, .failed, .done]
    public var isAttention: Bool { Self.attentionOrder.contains(self) }

    /// A terminal whose program is gone (exited, failed or shut down): there is nothing to type
    /// into until it runs again.
    public var hasEnded: Bool { self == .exited || self == .failed }

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

    /// Why the tile waits on the user, in a line: its question, its error, what it finished with.
    public var reason: String {
        if let detail { return detail }
        switch activity {
        case .needsInput: return "Waiting for an answer"
        case .failed: return "Failed"
        default: return "Finished"
        }
    }

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

/// Which tiles are working or waiting on the user. The Mac keeps this current as tiles change, so
/// the HUD and tabs don't depend on every tile's data.
public struct BoardState: Equatable, Sendable {
    public var working: Set<String> = []
    public var needsInput: Set<String> = []
    /// Failures and results the user hasn't seen.
    public var failed: Set<String> = []
    public var done: Set<String> = []
    /// Everything waiting on the user, in the order it is visited (`attentionQueue`).
    public var queue: [String] = []

    public init(_ tiles: [TileInfo] = []) {
        for tile in tiles where tile.activity == .working { working.insert(tile.id) }
        for tile in tiles.attentionQueue() {
            queue.append(tile.id)
            switch tile.activity {
            case .needsInput: needsInput.insert(tile.id)
            case .failed: failed.insert(tile.id)
            default: done.insert(tile.id)
            }
        }
    }

    /// Everything waiting on the user (`TileInfo.needsUser`).
    public var needsUser: Set<String> { Set(queue) }

    /// The most pressing state among `ids` that waits on the user, if any of them does.
    public func waiting(in ids: Set<String>) -> TileActivity? {
        zip(TileActivity.attentionOrder, [needsInput, failed, done]).first { !$0.1.isDisjoint(with: ids) }?.0
    }
}

public extension Sequence where Element == TileInfo {
    /// The one order tiles are visited in (⌘J, the HUD counters, ⌘K, the phone's queue): what waits
    /// on the user first, a question before a failure before an unseen result, and the oldest first.
    private func visitOrder() -> [TileInfo] { sorted { Self.place($0) < Self.place($1) } }

    private static func place(_ tile: TileInfo) -> (Int, Date, String) {
        let rank = tile.needsUser ? TileActivity.attentionOrder.firstIndex(of: tile.activity) : nil
        return (rank ?? TileActivity.attentionOrder.count, tile.lastActivityAt, tile.id)
    }

    /// The tiles waiting on the user, in the order they are visited.
    func attentionQueue() -> [TileInfo] { filter(\.needsUser).visitOrder() }

    /// The next of these tiles to visit, given the tile the user is on (nil: none): the first, or
    /// when they are on one of them and have seen it (a question put off, or opened in its app), the
    /// one after it, round again after the last. A tile that left them when it was visited (a result
    /// stops waiting once opened) is passed as it was then, and its old place says what is next.
    func next(after current: TileInfo?) -> String? {
        let order = visitOrder()
        guard let current else { return order.first?.id }
        if let i = order.firstIndex(where: { $0.id == current.id }) {
            return order[i].attention ? order.first?.id : order[(i + 1) % order.count].id
        }
        return (order.first { Self.place($0) > Self.place(current) } ?? order.first)?.id
    }
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

    /// The path with `.` and `..` resolved, for comparing folders.
    var standardizedPath: String { URL(fileURLWithPath: self).standardizedFileURL.path }

    /// `/Users/me/src/app` → `~/src/app`.
    var abbreviatingHome: String {
        hasPrefix(homeDirectory) ? "~" + dropFirst(homeDirectory.count) : self
    }
}

private let homeDirectory = NSHomeDirectory()
