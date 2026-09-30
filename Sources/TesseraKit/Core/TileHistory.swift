import Foundation

/// The tiles closed lately, newest first, for Undo and ⌘K's "Reopen …". Only the latest `limit`
/// are kept.
public struct RecentlyClosed<Tile: Identifiable> {
    public private(set) var tiles: [Tile]
    public let limit: Int

    public init(_ tiles: [Tile] = [], limit: Int = 20) {
        self.tiles = Array(tiles.prefix(limit))
        self.limit = limit
    }

    /// Records a close. A tile closed again has one record: the new one.
    public mutating func push(_ tile: Tile) {
        tiles.removeAll { $0.id == tile.id }
        tiles = Array(([tile] + tiles).prefix(limit))
    }

    /// Takes a tile off the list to bring it back; nil when it isn't on it.
    public mutating func take(_ id: Tile.ID) -> Tile? {
        tiles.firstIndex { $0.id == id }.map { tiles.remove(at: $0) }
    }
}
