import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Saved state is never silently lost: unreadable files are kept aside before being replaced.
@MainActor
final class StateFileTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-state-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func copies(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".unreadable-") }
    }

    func testMissingFileIsNotAProblem() throws {
        let dir = try tempDir()
        XCTAssertNil(StateFile.load([MachineConfig].self, from: dir.appendingPathComponent("machines.json")))
        XCTAssertEqual(try copies(in: dir), [])
    }

    func testUnreadableFileIsKeptAside() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("workspace.json")
        try Data("{\"tiles\": [".utf8).write(to: url)
        XCTAssertNil(StateFile.load(Workspace.Saved.self, from: url))
        let kept = try copies(in: dir)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("workspace.json.unreadable-"))
        XCTAssertTrue(StateFile.keptAside.contains { $0.lastPathComponent == kept[0] })
    }

    func testUnknownEntriesDropOutAloneAndTheFileIsKept() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("providers.json")
        try Data(#"[{"id":"a","kind":"openrouter","name":"OR"},{"id":"b","kind":"fromTheFuture","name":"?"}]"#.utf8).write(to: url)
        XCTAssertEqual(StateFile.loadList(UsageProviderConfig.self, from: url)?.map(\.id), ["a"])
        XCTAssertEqual(try copies(in: dir).count, 1)

        let board = dir.appendingPathComponent("workspace.json")
        try Data(#"{"tiles":[{"id":"t","kind":"terminal"},{"id":"x","kind":"hologram"}],"resumeOnLaunch":false}"#.utf8).write(to: board)
        let saved = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board))
        XCTAssertEqual(saved.tiles.compactMap(\.value).map(\.id), ["t"])
        XCTAssertEqual(saved.resumeOnLaunch, false)
    }

    func testSaveRoundTrips() throws {
        let url = try tempDir().appendingPathComponent("sub/machines.json")
        StateFile.save([MachineConfig(id: "m", name: "Box", sshHost: "box")], to: url)
        XCTAssertEqual(StateFile.loadList(MachineConfig.self, from: url)?.map(\.sshHost), ["box"])

        let board = url.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let tile = Workspace.Saved.Tile(id: "t", kind: .terminal, command: "claude", cwd: "/w", sessionId: "S")
        StateFile.save(Workspace.Saved(tiles: [Lossy(tile)], order: ["t", "claude:x"], hidden: ["claude:y": Date(timeIntervalSince1970: 5)],
                                       agentLookbackHours: 12), to: board)
        let saved = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: board))
        XCTAssertEqual(saved.tiles.compactMap(\.value).map(\.sessionId), ["S"])
        XCTAssertEqual(saved.order, ["t", "claude:x"])
        XCTAssertEqual(saved.hidden, ["claude:y": Date(timeIntervalSince1970: 5)])
        XCTAssertEqual(saved.agentLookbackHours, 12)
    }
}

/// App sessions aren't saved as tiles, but their places on the board are.
final class BoardOrderTests: XCTestCase {
    func testReappearingSessionReturnsAfterItsSavedNeighbour() {
        let saved = ["t1", "claude:a", "t2", "codex:b"]
        XCTAssertEqual(Workspace.restoredIndex(of: "claude:a", saved: saved, in: ["t1", "t2"]), 1)
        XCTAssertEqual(Workspace.restoredIndex(of: "codex:b", saved: saved, in: ["t1", "claude:a", "t2"]), 3)
        // Its neighbours are gone: nothing before it survives, so it leads.
        XCTAssertEqual(Workspace.restoredIndex(of: "claude:a", saved: saved, in: ["t2"]), 0)
        // Never saved: a new session goes last.
        XCTAssertEqual(Workspace.restoredIndex(of: "dsh:new", saved: saved, in: ["t1", "t2"]), 2)
    }

    func testSavedOrderKeepsOnlyWhatShouldComeBack() {
        let saved = ["t1", "claude:hidden", "t2", "gone", "codex:closed-for-good"]
        let order = Workspace.persistedOrder(["t2", "t1"], saved: saved) { $0 == "claude:hidden" }
        XCTAssertEqual(order, ["t2", "t1", "claude:hidden"])
        XCTAssertEqual(Workspace.persistedOrder([], saved: saved) { _ in false }, [])
    }
}

final class BoardLockTests: XCTestCase {
    func testSecondTakerSeesTheHolder() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-lock-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(BoardLock.take(in: dir))
        XCTAssertEqual(BoardLock.take(in: dir), getpid())
        // A folder that can't hold a lock doesn't stop a launch.
        XCTAssertNil(BoardLock.take(in: dir.appendingPathComponent("missing")))
    }
}
