import Foundation

/// ⌘K's search over tiles: what a query finds, best match first, so ⏎ jumps to the right one.
public enum TileSearch {
    /// A tile as the palette can find it: on the board, or a hidden conversation.
    public struct Candidate: Sendable {
        public var tile: TileInfo
        /// The name of the tab it is filed in.
        public var tab: String?
        public var hidden: Bool

        public init(tile: TileInfo, tab: String? = nil, hidden: Bool = false) {
            self.tile = tile
            self.tab = tab
            self.hidden = hidden
        }
    }

    /// How well `text` matches `query`, lower being better: 0 when it starts with it, 1 when one of
    /// its words does, 2 when it only contains it; nil when it doesn't.
    public static func match(_ query: String, in text: String) -> Int? {
        let text = text.lowercased(), query = query.lowercased()
        if text.hasPrefix(query) { return 0 }
        if text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { return 1 }
        return text.contains(query) ? 2 : nil
    }

    /// The candidates `query` finds. Every word of it must be in the tile's title, folder, tab or
    /// state; a match in the title counts most, then those in that order. Equal matches put tiles on
    /// the board before hidden ones, and the latest active first.
    public static func rank(_ query: String, _ candidates: [Candidate]) -> [Candidate] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func score(_ c: Candidate) -> Int? {
            if let title = match(query, in: c.tile.title) { return title }
            let fields = [c.tile.subtitle, c.tab ?? "", c.tile.activity.label]
            let scores = words.map { word in
                match(word, in: c.tile.title) ?? fields.firstIndex { match(word, in: $0) != nil }.map { $0 + 3 }
            }
            return scores.contains(nil) ? nil : scores.compactMap { $0 }.max()
        }
        return candidates.compactMap { c in score(c).map { (c, $0) } }
            .sorted { a, b in
                (a.1, a.0.hidden ? 1 : 0, b.0.tile.lastActivityAt, a.0.tile.id) < (b.1, b.0.hidden ? 1 : 0, a.0.tile.lastActivityAt, b.0.tile.id)
            }
            .map(\.0)
    }
}
