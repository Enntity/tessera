import Foundation

/// A tab on the board: one the user made, or one Tessera made to file work in.
public struct TileGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tileIds: [String]
    /// Tessera made it (auto tabs); it goes once it is empty. Renaming it makes it the user's.
    public var byTessera: Bool?
    /// The members Tessera filed here, free to be filed again; the rest the user put here.
    public var filed: [String]?

    public init(id: String = UUID().uuidString, name: String, tileIds: [String] = [], byTessera: Bool = false) {
        self.id = id
        self.name = name
        self.tileIds = tileIds
        self.byTessera = byTessera ? true : nil
    }

    public var isTessera: Bool { byTessera == true }
}

/// The board's tabs. A tile lives in at most one tab (like a folder); "All" always shows everything.
/// Where the user puts a tile, it stays: dragged onto a tab or back to All. Every other tile is
/// Tessera's to file — beside the work it was spawned from, or where the organizer puts it.
public struct TileGroups: Codable, Hashable, Sendable {
    public private(set) var list: [TileGroup] = []
    /// Tiles the user took out of every tab: they stay on All alone.
    public private(set) var keptOnAll: Set<String> = []

    public init(_ list: [TileGroup] = [], keptOnAll: Set<String> = []) {
        self.list = list
        self.keptOnAll = keptOnAll
    }

    @discardableResult
    public mutating func create(named name: String, byTessera: Bool = false) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TileGroup(name: clean.isEmpty ? "Tab \(list.count + 1)" : clean, byTessera: byTessera)
        list.append(group)
        return group.id
    }

    /// The user's name for it: a tab Tessera made is the user's from then on.
    public mutating func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = clean
        list[i].byTessera = nil
    }

    /// Deleting a tab never closes its tiles; they stay on All.
    public mutating func delete(_ id: String) {
        list.removeAll { $0.id == id }
    }

    /// The user moves a tile into a tab, or out of every tab when `groupId` is nil: either way it
    /// stays where they put it.
    public mutating func assign(_ tileId: String, to groupId: String?) {
        place(tileId, in: groupId, filed: false)
        if groupId == nil { keptOnAll.insert(tileId) } else { keptOnAll.remove(tileId) }
    }

    /// A tile that is gone (closed) leaves every tab, and whatever the user said about it.
    public mutating func forget(_ tileId: String) {
        place(tileId, in: nil, filed: false)
        keptOnAll.remove(tileId)
    }

    /// Tessera files a tile in a tab. Only one the user hasn't placed moves; true when it did.
    @discardableResult
    public mutating func file(_ tileId: String, to groupId: String) -> Bool {
        guard isMovable(tileId), group(of: tileId)?.id != groupId, list.contains(where: { $0.id == groupId }) else { return false }
        place(tileId, in: groupId, filed: true)
        return true
    }

    /// Nobody has put it anywhere, or only Tessera has.
    public func isMovable(_ tileId: String) -> Bool {
        guard !keptOnAll.contains(tileId) else { return false }
        guard let group = group(of: tileId) else { return true }
        return group.filed?.contains(tileId) == true
    }

    /// Spawned work goes where the work it came from is (`origins`: tile → the tile it came from),
    /// along a chain of spawns, and again whenever that moves. True when anything moved.
    @discardableResult
    public mutating func follow(_ origins: [String: String]) -> Bool {
        var moved = false
        for tile in origins.keys.sorted() {
            var seen: Set<String> = [tile]
            var origin = origins[tile]
            // The nearest tab up the chain.
            while let o = origin, seen.insert(o).inserted, group(of: o) == nil { origin = origins[o] }
            if let o = origin, let tab = group(of: o)?.id, file(tile, to: tab) { moved = true }
        }
        return moved
    }

    /// Drops the tabs Tessera made that no longer hold a tile on the board.
    public mutating func prune(existing: Set<String>) {
        list.removeAll { $0.isTessera && !$0.tileIds.contains(where: existing.contains) }
    }

    public func group(of tileId: String) -> TileGroup? {
        list.first { $0.tileIds.contains(tileId) }
    }

    public func members(of groupId: String) -> Set<String> {
        Set(list.first { $0.id == groupId }?.tileIds ?? [])
    }

    private mutating func place(_ tileId: String, in groupId: String?, filed: Bool) {
        for i in list.indices {
            list[i].tileIds.removeAll { $0 == tileId }
            list[i].filed?.removeAll { $0 == tileId }
            if list[i].filed?.isEmpty == true { list[i].filed = nil }
        }
        guard let groupId, let i = list.firstIndex(where: { $0.id == groupId }) else { return }
        list[i].tileIds.append(tileId)
        if filed { list[i].filed = (list[i].filed ?? []) + [tileId] }
    }
}
