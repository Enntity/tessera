import Foundation

/// Desktop agent apps Tessera can open, with conversation links where the app supports them.
public enum AgentApp: String, Codable, CaseIterable, Sendable {
    case claude, codex, deepseekHarness, zcode

    public var bundleID: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .deepseekHarness: "com.deepseek.dsh"
        case .zcode: "com.enntity.zcode"
        }
    }

    public var flavor: AgentFlavor {
        switch self {
        case .claude: .claudeDesktop
        case .codex: .codexDesktop
        case .deepseekHarness: .dsh
        case .zcode: .zcodeDesktop
        }
    }

    /// The app whose conversations have this flavor.
    public init?(flavor: AgentFlavor) {
        guard let app = Self.allCases.first(where: { $0.flavor == flavor }) else { return nil }
        self = app
    }

    /// The app a tile of `flavor` opens in, or nil when it opens on the board instead: terminals,
    /// pages and dsh sessions, a conversation whose app isn't installed, and anything opened with
    /// `inApp` off (paging between open tiles, Show Transcript).
    public static func opening(_ flavor: AgentFlavor, installed: [AgentApp], inApp: Bool = true) -> AgentApp? {
        guard inApp, let app = AgentApp(flavor: flavor), app.routesExistingSessions, installed.contains(app) else { return nil }
        return app
    }

    public var routesExistingSessions: Bool { self == .claude || self == .codex }

    public var name: String { flavor.displayName + " app" }

    public var canCreateConversation: Bool { self == .claude || self == .codex }
    public var newLabel: String {
        switch self {
        case .claude: "New Claude session (app)"
        case .codex: "New Codex thread (app)"
        case .deepseekHarness: "Open DeepSeek Harness"
        case .zcode: "Open Enntity ZCode"
        }
    }

    /// The deep link to an existing conversation: `claude://code/continue?session=…` / `codex://threads/…`.
    public func conversationURL(_ id: String) -> URL? {
        switch self {
        case .claude:
            var c = URLComponents(string: "claude://code/continue")
            c?.queryItems = [URLQueryItem(name: "session", value: id)]
            return c?.url
        case .codex: return URL(string: "codex://threads/\(id)")
        case .deepseekHarness, .zcode: return nil
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
        case .deepseekHarness, .zcode:
            return nil
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
