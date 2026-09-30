import Foundation

/// What the filter field and its chips narrow the board to, within the tab being viewed.
public struct BoardQuery: Equatable, Sendable {
    /// A filter chip: what a tile is doing (a state), or what it is (a kind).
    public enum Chip: String, CaseIterable, Identifiable, Sendable {
        case needsYou, working
        case terminals, claude, codex, dsh, web

        public var id: String { rawValue }

        /// The state a state chip stands for; nil for a kind.
        public var activity: TileActivity? {
            switch self {
            case .needsYou: .needsInput
            case .working: .working
            case .terminals, .claude, .codex, .dsh, .web: nil
            }
        }

        /// The tool whose glyph a kind chip wears; nil for a state.
        public var flavor: AgentFlavor? {
            switch self {
            case .needsYou, .working: nil
            case .terminals: .shell
            case .claude: .claudeDesktop
            case .codex: .codexDesktop
            case .dsh: .dsh
            case .web: .web
            }
        }

        public var label: String {
            switch self {
            // Everything in the queue (questions, failures, unseen results), not questions alone.
            case .needsYou: TileActivity.needsYouLabel
            case .terminals: "Terminals"
            case .dsh: "dsh"
            default: activity?.label ?? flavor?.displayName ?? rawValue
            }
        }

        public func holds(_ tile: TileInfo) -> Bool {
            switch self {
            case .needsYou: tile.needsUser
            case .working: tile.activity == .working
            case .terminals: tile.kind == .terminal
            case .claude: tile.flavor == .claude || tile.flavor == .claudeDesktop
            case .codex: tile.flavor == .codex || tile.flavor == .codexDesktop
            case .dsh: tile.flavor == .dsh
            case .web: tile.kind == .browser
            }
        }
    }

    /// Which tiles each chip holds. The Mac keeps this current as tiles change (like `BoardState`),
    /// so the chips and the narrowed board don't depend on every tile's data.
    public typealias Holdings = [Chip: Set<String>]

    public static func holdings(of tiles: some Sequence<TileInfo>) -> Holdings {
        var holdings = Holdings()
        for tile in tiles {
            for chip in Chip.allCases where chip.holds(tile) { holdings[chip, default: []].insert(tile.id) }
        }
        return holdings
    }

    /// What was typed.
    public var text = ""
    /// The chips that are on.
    public var chips: Set<Chip> = []

    public init(text: String = "", chips: Set<Chip> = []) {
        self.text = text
        self.chips = chips
    }

    /// Something is typed that can find a tile (blanks alone find nothing).
    public var hasText: Bool { !text.allSatisfy(\.isWhitespace) }
    public var isEmpty: Bool { !hasText && chips.isEmpty }

    /// The tiles the text finds among `candidates` (see `TileSearch.score`); nil with nothing typed.
    public func find(in candidates: [TileSearch.Candidate]) -> Set<String>? {
        guard hasText else { return nil }
        return Set(candidates.filter { TileSearch.score(text, $0) != nil }.map(\.tile.id))
    }

    /// `ids` narrowed to the tiles the text found (nil: nothing typed) and the chips hold. Chips of one
    /// sort widen each other (Claude or Codex); the two sorts, and the text, narrow (Claude, working).
    /// `kept` (the open tile) stays whatever it has become.
    public func narrow(_ ids: [String], found: Set<String>?, holdings: Holdings, keeping kept: String? = nil) -> [String] {
        isEmpty ? ids : ids.filter { $0 == kept || Self.passes($0, found: found, holdings: holdings, chips: chips) }
    }

    /// The number on a chip: how many of `ids` it holds among those the text and the chips of the
    /// other sort leave.
    public func count(_ chip: Chip, in ids: [String], found: Set<String>?, holdings: Holdings) -> Int {
        let others = chips.filter { ($0.activity == nil) != (chip.activity == nil) }
        return ids.filter { Self.passes($0, found: found, holdings: holdings, chips: others.union([chip])) }.count
    }

    private static func passes(_ id: String, found: Set<String>?, holdings: Holdings, chips: Set<Chip>) -> Bool {
        guard found?.contains(id) != false else { return false }
        func held(_ sort: [Chip]) -> Bool { sort.isEmpty || sort.contains { holdings[$0]?.contains(id) == true } }
        return held(chips.filter { $0.activity != nil }) && held(chips.filter { $0.activity == nil })
    }
}
