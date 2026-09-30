import Foundation

/// The search over tiles behind ⌘K and the board's filter: what a query finds, and for ⌘K the best
/// match first, so ⏎ jumps to the right one.
public enum TileSearch {
    /// A tile as it can be found: on the board, or a hidden conversation.
    public struct Candidate: Sendable {
        public var tile: TileInfo
        /// The name of the tab it is filed in.
        public var tab: String?
        public var hidden: Bool
        /// What the tile shows: a terminal's screen, a conversation's latest messages.
        public var text: String

        public init(tile: TileInfo, tab: String? = nil, hidden: Bool = false, text: String = "") {
            self.tile = tile
            self.tab = tab
            self.hidden = hidden
            self.text = text
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

    private static func words(_ query: String) -> [String] { query.split(separator: " ").map(String.init) }

    /// How well a candidate matches `query`, lower being better; nil when it doesn't. Every word of
    /// the query must be in the tile's title, folder, detail (its question, its error), tab, state or
    /// what it shows; a match in the title counts most, then those in that order.
    public static func score(_ query: String, _ c: Candidate) -> Int? {
        let query = query.trimmingCharacters(in: .whitespaces)
        let words = words(query)
        guard !words.isEmpty else { return nil }
        if let title = match(query, in: c.tile.title) { return title }
        // A tile in the queue answers to its state and to "needs you".
        let state = c.tile.activity.label + (c.tile.needsUser ? " " + TileActivity.needsYouLabel : "")
        let fields = [c.tile.subtitle, c.tile.detail ?? "", c.tab ?? "", state, c.text]
        let scores = words.map { word in
            match(word, in: c.tile.title) ?? fields.firstIndex { match(word, in: $0) != nil }.map { $0 + 3 }
        }
        return scores.contains(nil) ? nil : scores.compactMap { $0 }.max()
    }

    /// Where the words of `query` are in `text`, in order and merged where they overlap: what the
    /// board lights up in a title it found.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for word in words(query) {
            var from = text.startIndex
            while let range = text.range(of: word, options: .caseInsensitive, range: from..<text.endIndex) {
                found.append(range)
                from = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }

    /// The candidates `query` finds, best first (see `score`). Equal matches put tiles on the board
    /// before hidden ones, and the latest active first.
    public static func rank(_ query: String, _ candidates: [Candidate]) -> [Candidate] {
        candidates.compactMap { c in score(query, c).map { (c, $0) } }
            .sorted { a, b in
                (a.1, a.0.hidden ? 1 : 0, b.0.tile.lastActivityAt, a.0.tile.id) < (b.1, b.0.hidden ? 1 : 0, a.0.tile.lastActivityAt, b.0.tile.id)
            }
            .map(\.0)
    }
}
