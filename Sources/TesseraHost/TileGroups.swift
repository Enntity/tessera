import Foundation

/// A user-made tab on the board.
public struct TileGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tileIds: [String]

    public init(id: String = UUID().uuidString, name: String, tileIds: [String] = []) {
        self.id = id
        self.name = name
        self.tileIds = tileIds
    }
}

/// The user's tabs. A tile lives in at most one tab (like a folder); "All" always shows everything.
public struct TileGroups: Codable, Hashable, Sendable {
    public private(set) var list: [TileGroup] = []

    public init(_ list: [TileGroup] = []) {
        self.list = list
    }

    @discardableResult
    public mutating func create(named name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TileGroup(name: clean.isEmpty ? "Tab \(list.count + 1)" : clean)
        list.append(group)
        return group.id
    }

    public mutating func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = clean
    }

    /// Deleting a tab never closes its tiles; they stay on All.
    public mutating func delete(_ id: String) {
        list.removeAll { $0.id == id }
    }

    /// Moves a tile into a tab, or out of every tab when `groupId` is nil.
    public mutating func assign(_ tileId: String, to groupId: String?) {
        for i in list.indices { list[i].tileIds.removeAll { $0 == tileId } }
        guard let groupId, let i = list.firstIndex(where: { $0.id == groupId }) else { return }
        list[i].tileIds.append(tileId)
    }

    public func group(of tileId: String) -> TileGroup? {
        list.first { $0.tileIds.contains(tileId) }
    }

    public func members(of groupId: String) -> Set<String> {
        Set(list.first { $0.id == groupId }?.tileIds ?? [])
    }
}
