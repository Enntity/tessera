import Foundation

/// The desktop agent apps Tessera can start new conversations in, via their own deep links.
public enum AgentApp: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var bundleID: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
    }

    public var flavor: AgentFlavor { self == .claude ? .claudeDesktop : .codexDesktop }

    /// The app whose conversations have this flavor.
    public init?(flavor: AgentFlavor) {
        guard let app = Self.allCases.first(where: { $0.flavor == flavor }) else { return nil }
        self = app
    }

    /// The app a tile of `flavor` opens in, or nil when it opens on the board instead: terminals,
    /// pages and dsh sessions, a conversation whose app isn't installed, and anything opened with
    /// `inApp` off (paging between open tiles, Show Transcript).
    public static func opening(_ flavor: AgentFlavor, installed: [AgentApp], inApp: Bool = true) -> AgentApp? {
        guard inApp, let app = AgentApp(flavor: flavor), installed.contains(app) else { return nil }
        return app
    }

    public var name: String { flavor.displayName + " app" }

    public var newLabel: String { self == .claude ? "New Claude session (app)" : "New Codex thread (app)" }

    /// The deep link to an existing conversation: `claude://code/continue?session=…` / `codex://threads/…`.
    public func conversationURL(_ id: String) -> URL? {
        switch self {
        case .claude:
            var c = URLComponents(string: "claude://code/continue")
            c?.queryItems = [URLQueryItem(name: "session", value: id)]
            return c?.url
        case .codex: return URL(string: "codex://threads/\(id)")
        }
    }

    /// `claude://code/new?folder=…&q=…` / `codex://threads/new?path=…&prompt=…`. The prompt is
    /// placed in the app's composer; nothing is sent until the user sends it.
    public func newConversationURL(folder: String?, prompt: String?) -> URL? {
        var c = URLComponents()
        var items: [URLQueryItem] = []
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .claude:
            c.scheme = "claude"
            c.host = "code"
            c.path = "/new"
            if let folder, !folder.isEmpty { items.append(.init(name: "folder", value: folder)) }
            if let text, !text.isEmpty { items.append(.init(name: "q", value: text)) }
        case .codex:
            c.scheme = "codex"
            c.host = "threads"
            c.path = "/new"
            if let folder, !folder.isEmpty { items.append(.init(name: "path", value: folder)) }
            if let text, !text.isEmpty { items.append(.init(name: "prompt", value: text)) }
        }
        // The apps parse these like web URLs (`+` means space), so encode values strictly.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        c.percentEncodedQueryItems = items.isEmpty ? nil : items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return c.url
    }
}
