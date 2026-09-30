import CoreGraphics

/// The watch dock: the tiles kept open beside the board, live, in the order they were docked.
public struct WatchDock: Equatable, Sendable {
    /// How many tiles it holds.
    public static let capacity = 2

    public private(set) var ids: [String]

    public init(_ ids: [String] = []) {
        var seen: Set<String> = []
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.capacity))
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Docks `id` under what is there. In a full dock the tile docked longest makes room for it,
    /// and is returned.
    @discardableResult
    public mutating func add(_ id: String) -> String? {
        guard !contains(id) else { return nil }
        let left = ids.count == Self.capacity ? ids.removeFirst() : nil
        ids.append(id)
        return left
    }

    /// False when `id` wasn't docked.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        ids.remove(at: index)
        return true
    }

}

/// The columns beside the board, in a window `width` wide: the lane and the accounts where the
/// user has them open, and the dock while anything is docked.
public struct BoardColumns: Equatable, Sendable {
    public var lane: Bool
    public var accounts: Bool
    /// How wide the dock is; nil with nothing docked.
    public var dock: CGFloat?
    /// The widest it can be dragged.
    public var dockMax: CGFloat = 0

    /// The dock is as wide as the user `chose`, no narrower than `dockMin`, and leaves the board
    /// `boardMin`. In a window too small for all of it, the accounts make way for the dock, then
    /// the lane does (they are back when there is room); smaller still, dock and board share.
    public init(width: CGFloat, lane: CGFloat?, accounts: CGFloat?, dock chosen: CGFloat?, dockMin: CGFloat, boardMin: CGFloat) {
        var room = width - (lane ?? 0) - (accounts ?? 0)
        self.lane = lane != nil
        self.accounts = accounts != nil
        guard let chosen else { return }
        if room < dockMin + boardMin, let accounts {
            self.accounts = false
            room += accounts
        }
        if room < dockMin + boardMin, let lane {
            self.lane = false
            room += lane
        }
        dockMax = max(room - boardMin, room / 2, 0)
        dock = min(max(chosen, dockMin), dockMax)
    }
}

/// How small tiles get before the board scrolls rather than shrink them further: a step down shows
/// more tiles at once, a step up makes them larger (⌘- ⌘=).
public struct BoardDensity: RawRepresentable, Equatable, Sendable {
    /// The least width of a tile, at each step.
    public static let widths: [CGFloat] = [170, 200, 230, 280, 340, 420]
    public static let standard = BoardDensity(rawValue: 2)

    public let rawValue: Int

    /// A step off either end is the last one there.
    public init(rawValue: Int) {
        self.rawValue = min(max(rawValue, 0), Self.widths.count - 1)
    }

    public var minTileWidth: CGFloat { Self.widths[rawValue] }

    /// The next step towards larger tiles (`by: 1`) or smaller ones (`by: -1`); nil at the last.
    public func stepped(by steps: Int) -> BoardDensity? {
        let next = BoardDensity(rawValue: rawValue + steps)
        return next == self ? nil : next
    }
}

/// A key and what it does, for the strip along the bottom of an open panel.
public struct KeyHint: Equatable, Sendable, Identifiable {
    public let keys: String
    public let label: String

    public var id: String { keys }

    public init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    /// What the keyboard does in the open panel of `tile`: how to leave it first, then what its
    /// kind adds, then what works everywhere. `suspended`: a terminal that was shut down; `app`:
    /// the app a conversation's transcript opens in; `live`: the panel holds a page of its own (dsh).
    public static func panel(_ tile: TileInfo, suspended: Bool = false, app: String? = nil, live: Bool = false) -> [KeyHint] {
        var hints: [KeyHint] = []
        switch tile.kind {
        case .terminal where tile.activity.hasEnded:
            hints = [KeyHint("⏎", suspended ? "resume" : "restart"), KeyHint("esc", "board")]
        case .agentSession where !live:
            hints = [KeyHint("esc", "board")] + (app.map { [KeyHint("⌘O", "open in \($0)")] } ?? [])
        case .browser:
            // A live terminal or page gets Esc itself.
            hints = [KeyHint("⌘⏎", "board"), KeyHint("⌘L", "address")]
        case .terminal, .agentSession:
            hints = [KeyHint("⌘⏎", "board")]
        }
        return hints + [KeyHint("⌘D", "dock"), KeyHint("⌘[ ⌘]", "other tiles"), KeyHint("⌘J", "next needs-you"), KeyHint("⌘K", "find")]
    }
}
