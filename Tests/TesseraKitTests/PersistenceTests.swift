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
    }
}
