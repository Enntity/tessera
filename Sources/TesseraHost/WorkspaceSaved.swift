import Foundation
import TesseraKit

/// A tile the user closed, as it read on the board, with what brings it back: a terminal's command,
/// folder and conversation, a page's address, and the tab it was filed in. (A hidden app
/// conversation needs none of that: it is only shown again.)
public struct ClosedTile: Codable, Identifiable {
    public var id: String { tile.id }
    public var kind: TileKind { tile.kind }
    public let title: String
    public let subtitle: String
    var tile: Workspace.Saved.Tile
    var tab: String?
}

extension Workspace {
    /// The board as it is saved (`workspace.json`).
    struct Saved: Codable {
        struct Tile: Codable {
            var id: String
            var kind: TileKind
            var command: String?
            var cwd: String?
            var title: String?
            var url: String?
            var sessionId: String?
            var suspended: Bool?
        }
        var tiles: [Lossy<Tile>]
        var defaultDirectory: String?
        var placeNativeWindows: Bool?
        var groups: [TileGroup]?
        var resumeOnLaunch: Bool?
        /// Every tile's place, app sessions included (they aren't in `tiles`).
        var order: [String]?
        /// App sessions the user closed, and when.
        var hidden: [String: Date]?
        var agentLookbackHours: Double?
        /// Names the user gave app sessions (a terminal's or page's is in its tile).
        var titles: [String: String]?
        /// Tiles closed lately, newest first.
        var closed: [Lossy<ClosedTile>]?
        /// The tiles in the watch dock, and how wide the user made it.
        var dock: [String]?
        var dockWidth: Double?
    }

    /// Where a tile that reappears (an app session found again after launch) goes: right after the
    /// nearest tile that preceded it when saved, at the front if none of those is on the board, or at
    /// the end if it was never saved.
    nonisolated static func restoredIndex(of id: String, saved: [String], in order: [String]) -> Int {
        guard let i = saved.firstIndex(of: id) else { return order.endIndex }
        for previous in saved[..<i].reversed() {
            if let j = order.firstIndex(of: previous) { return j + 1 }
        }
        return 0
    }

    /// The board's order plus the saved ids `keep` wants remembered, each at its old place.
    nonisolated static func persistedOrder(_ order: [String], saved: [String], keep: (String) -> Bool) -> [String] {
        var result = order
        for id in saved where !result.contains(id) && keep(id) {
            result.insert(id, at: restoredIndex(of: id, saved: saved, in: result))
        }
        return result
    }
}
