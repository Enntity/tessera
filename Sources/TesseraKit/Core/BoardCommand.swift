import Foundation

/// Commands on many tiles at once (⌘K and the Board menu).
public enum BoardCommand: String, CaseIterable, Identifiable, Sendable {
    case markAllSeen, closeExited, restartFailed, hideIdle, showHidden, shutDownAll, resumeAll

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .markAllSeen: "Mark All Seen"
        case .closeExited: "Close Exited"
        case .restartFailed: "Restart Failed"
        case .hideIdle: "Hide Idle Conversations"
        case .showHidden: "Show Hidden Conversations"
        case .shutDownAll: "Shut Down All Terminals"
        case .resumeAll: "Resume All Terminals"
        }
    }

    public var symbol: String {
        switch self {
        case .markAllSeen, .showHidden: "eye"
        case .closeExited: TileKind.terminal.closeSymbol
        case .restartFailed: "arrow.clockwise"
        case .hideIdle: TileKind.agentSession.closeSymbol
        case .shutDownAll: "power"
        case .resumeAll: "play.fill"
        }
    }

    /// Shut Down All and Resume All reach every tab; the others keep to the tab being viewed.
    public var everyTab: Bool { self == .shutDownAll || self == .resumeAll }

    /// Whether it would act on `tile`, a tile on the board (`suspended`: a terminal that was shut down).
    public func applies(to tile: TileInfo, suspended: Bool) -> Bool {
        switch self {
        case .markAllSeen: tile.attention
        // A terminal the user shut down is kept for Resume.
        case .closeExited: tile.kind == .terminal && tile.activity == .exited && !suspended
        case .restartFailed: tile.kind == .terminal && tile.activity == .failed
        case .hideIdle: tile.kind == .agentSession && tile.activity == .idle
        // Hidden conversations aren't on the board.
        case .showHidden: false
        case .shutDownAll: tile.kind == .terminal && !suspended
        case .resumeAll: suspended
        }
    }
}
