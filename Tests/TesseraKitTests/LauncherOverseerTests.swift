import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Where new tiles start: the folders used lately, and the folders a typed path finds.
final class StartFoldersTests: XCTestCase {
    /// A small disk: `/home/me` holds `src`, `software`, `.config` and a file.
    private let disk: [String: [String]] = [
        "/": ["home", "opt", "etc.conf"],
        "/home": ["me"],
        "/opt": [],
        "/home/me": ["src", "software", ".config", "notes.txt"],
        "/home/me/software": ["ml", "Music"],
        "/home/me/software/ml": [],
        "/home/me/software/Music": [],
        "/home/me/src": [],
        "/home/me/.config": []
    ]

    private func find(_ typed: String, limit: Int = 8) -> [String] {
        StartFolders.completions(of: typed, home: "/home/me", limit: limit) { [disk] in disk[$0] }
    }

    func testOnlyAPathIsReadAsAFolder() {
        XCTAssertTrue(StartFolders.looksLikePath("~"))
        XCTAssertTrue(StartFolders.looksLikePath("~/src"))
        XCTAssertTrue(StartFolders.looksLikePath("/opt"))
        XCTAssertFalse(StartFolders.looksLikePath("claude"))
        XCTAssertFalse(StartFolders.looksLikePath("~user"))
        XCTAssertFalse(StartFolders.looksLikePath(""))
    }

    func testATypedPrefixFindsTheFoldersItBegins() {
        XCTAssertEqual(find("~/s"), ["/home/me/software", "/home/me/src"])
        XCTAssertEqual(find("~/SO"), ["/home/me/software"])
        // Files are not folders, and hidden folders wait to be asked for.
        XCTAssertEqual(find("~/n"), [])
        XCTAssertEqual(find("~/."), ["/home/me/.config"])
    }

    func testAFolderTypedInFullComesFirstThenWhatIsInIt() {
        XCTAssertEqual(find("~"), ["/home/me", "/home/me/software", "/home/me/src"])
        XCTAssertEqual(find("~/software/"), ["/home/me/software", "/home/me/software/ml", "/home/me/software/Music"])
        XCTAssertEqual(find("/home/me/software"), ["/home/me/software"])
        XCTAssertEqual(find("/"), ["/", "/home", "/opt"])
    }

    func testNothingIsFoundWhereThereIsNoFolder() {
        XCTAssertEqual(find("~/nowhere/"), [])
        XCTAssertEqual(find("/home/you/s"), [])
        XCTAssertEqual(find("claude"), [])
    }

    func testTheListIsKeptShort() {
        XCTAssertEqual(find("~", limit: 2), ["/home/me", "/home/me/software"])
    }

    func testAFolderUsedAgainMovesToTheFront() {
        var recent: [String] = []
        for dir in ["/a", "/b", "/a/../a", "/c"] { recent = StartFolders.remembering(dir, in: recent) }
        XCTAssertEqual(recent, ["/c", "/a", "/b"])
        for i in 0..<20 { recent = StartFolders.remembering("/d\(i)", in: recent) }
        XCTAssertEqual(recent.count, StartFolders.limit)
        XCTAssertEqual(recent.first, "/d19")
    }
}

/// The overseer: an agent in a folder of its own, told there what it is for.
@MainActor
final class OverseerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-overseer-\(UUID().uuidString.prefix(6))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testItsFolderSaysWhatItIsForToWhicheverAgentRunsThere() throws {
        let dir = try tempDir()
        try Overseer.prepare(dir)
        let role = try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(role, Overseer.role)
        XCTAssertTrue(role.contains("Accord"))
        // Claude Code reads CLAUDE.md, which hands it the same role.
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
        // Its own tools need no asking: seeing the board and reaching agents is what it is for.
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".claude/settings.json"))) as? [String: Any]
        let allowed = (settings?["permissions"] as? [String: Any])?["allow"] as? [String]
        XCTAssertEqual(allowed, ["mcp__accord", "mcp__tessera"])
    }

    func testARoleTheUserRewroteIsLeftAlone() throws {
        let dir = try tempDir()
        try Overseer.prepare(dir)
        let role = dir.appendingPathComponent("AGENTS.md")
        try "Mine now.".write(to: role, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("CLAUDE.md"))
        try Overseer.prepare(dir)
        XCTAssertEqual(try String(contentsOf: role, encoding: .utf8), "Mine now.")
        // What went missing is put back.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("CLAUDE.md").path))
    }

    /// A board of its own, in a throwaway folder.
    private func board() throws -> (Workspace, URL) {
        // Only a debug build takes its folder from the environment: any other would open the user's own board.
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        // Never a real agent: something that only sits there.
        workspace.overseerCommand = "cat"
        addTeardownBlock { @MainActor in workspace.prepareForQuit() }
        return (workspace, dir)
    }

    func testTheOverseerIsOneTileInItsOwnFolder() throws {
        let (workspace, dir) = try board()
        let id = try XCTUnwrap(workspace.overseer())
        let tile = try XCTUnwrap(workspace.info(id))
        XCTAssertEqual(tile.title, Overseer.title)
        XCTAssertEqual(workspace.terminals[id]?.cwd, dir.appendingPathComponent("overseer").path)
        XCTAssertEqual(workspace.terminals[id]?.command, "cat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("overseer/AGENTS.md").path))
        // Asked for again, it is the same tile.
        XCTAssertEqual(workspace.overseer(), id)
        XCTAssertEqual(workspace.overseerId, id)
        // Its folder is its own: nothing else is offered a start there.
        XCTAssertFalse(workspace.recentDirectories.contains(dir.appendingPathComponent("overseer").path))
    }

    func testAnOverseerShutDownComesBackAndOneClosedIsStartedAgain() throws {
        let (workspace, _) = try board()
        let id = try XCTUnwrap(workspace.overseer())
        workspace.shutDown(id)
        XCTAssertTrue(workspace.isSuspended(id))
        XCTAssertEqual(workspace.overseer(), id)
        XCTAssertFalse(workspace.isSuspended(id))
        XCTAssertEqual(workspace.terminals[id]?.isRunning, true)
        // Closed, the next one is a new tile; the closed one, reopened, is the overseer no longer.
        XCTAssertNotNil(workspace.close(id))
        let next = try XCTUnwrap(workspace.overseer())
        XCTAssertNotEqual(next, id)
        XCTAssertEqual(workspace.overseerId, next)
    }

    func testAQuestionStartsANewOverseerAndIsNeverAskedAgain() throws {
        let (workspace, _) = try board()
        workspace.overseerCommand = "echo"
        let id = try XCTUnwrap(workspace.overseer(asking: "How's the port; any blockers?"))
        // It was handed the question as it started; what the tile brings back is the agent alone.
        XCTAssertEqual(workspace.terminals[id]?.command, "echo")
        XCTAssertEqual(ShellWords.split(ShellWords.join(["echo", "How's the port; any blockers?"])), ["echo", "How's the port; any blockers?"])
    }

    func testANameGivenThroughAccordShowsOnTheTileUnlessTheUserNamedIt() throws {
        let (workspace, dir) = try board()
        let id = workspace.launch(command: "cat", cwd: dir.path)
        let own = try XCTUnwrap(workspace.info(id)?.title)
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: "GLM port", changedAt: nil)]
        XCTAssertEqual(workspace.info(id)?.title, "GLM port")
        // A name of the user's own wins, and taking it away shows the given one again.
        workspace.rename(id, to: "Mine")
        XCTAssertEqual(workspace.info(id)?.title, "Mine")
        workspace.rename(id, to: "")
        XCTAssertEqual(workspace.info(id)?.title, "GLM port")
        workspace.accord.tileRecords = [id: .init(address: "mac/observed-1", givenTitle: nil, changedAt: nil)]
        XCTAssertEqual(workspace.info(id)?.title, own)
    }

    func testTheOverseerIsRememberedAcrossLaunches() throws {
        let (workspace, dir) = try board()
        let id = try XCTUnwrap(workspace.overseer())
        workspace.save()
        let saved = try XCTUnwrap(StateFile.load(Workspace.Saved.self, from: dir.appendingPathComponent("workspace.json")))
        XCTAssertEqual(saved.overseer, id)
    }

    func testFoldersTilesStartInAreOfferedAgainLatestFirst() throws {
        let (workspace, dir) = try board()
        let (a, b) = (dir.appendingPathComponent("a").path, dir.appendingPathComponent("b").path)
        for path in [a, b] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let before = workspace.recentDirectories
        workspace.noteDirectory(a)
        workspace.noteDirectory(b)
        workspace.noteDirectory(a)
        XCTAssertEqual(Array(workspace.recentDirectories.prefix(2)), [a, b])
        // A folder that is gone is not offered.
        try FileManager.default.removeItem(atPath: b)
        XCTAssertEqual(workspace.recentDirectories.first, a)
        XCTAssertFalse(workspace.recentDirectories.contains(b))
        Preferences.store.set(before, forKey: "tessera.recentDirectories")
    }
}

/// What Accord holds about a tile, as the board and its listing for agents show it.
@MainActor
final class AccordTileRecordTests: XCTestCase {
    func testAccordsRecordOfATileIsItsAddressItsGivenNameAndWhenItChanged() {
        let sessions: [[String: Any]] = [
            ["source": "tessera", "externalId": "tile-1", "address": "mac/observed-1", "title": "devin",
             "givenTitle": "Hardware tests", "progressAt": 9_000_000.0],
            ["source": "tessera", "externalId": "tile-2", "address": "mac/observed-2", "title": "omp", "givenTitle": ""],
            // An agent's own session is not a tile, and a tile Accord gave no address is not reachable.
            ["source": "agent", "address": "mac/agent", "title": "claude", "givenTitle": "Not a tile"],
            ["source": "tessera", "externalId": "tile-3", "title": "no address"],
            // Another host's Tessera has tiles of its own: its sessions never name or stand for this Mac's.
            ["source": "tessera", "externalId": "tile-1", "address": "elsewhere/observed-9", "title": "devin", "givenTitle": "Not this Mac's"],
            ["source": "tessera", "externalId": "tile-4", "address": "elsewhere/observed-4", "title": "omp"]
        ]
        let records = AccordBridge.tileRecords(sessions, authority: "mac")
        XCTAssertEqual(records.keys.sorted(), ["tile-1", "tile-2"])
        XCTAssertEqual(records["tile-1"], .init(address: "mac/observed-1", givenTitle: "Hardware tests",
                                                changedAt: Date(timeIntervalSince1970: 9000)))
        XCTAssertEqual(records["tile-2"], .init(address: "mac/observed-2", givenTitle: nil, changedAt: nil))
    }

    func testTheListingForAgentsSaysWhereToReachATileAndHowOldItsSummaryIs() {
        let now = Date(timeIntervalSince1970: 10_000)
        let tile = TileInfo(id: "tile-1", kind: .terminal, flavor: .shell, title: "Hardware tests", subtitle: "~/src",
                            activity: .idle, lastActivityAt: Date(timeIntervalSince1970: 9_940))
        let record = AccordBridge.TileRecord(address: "mac/observed-1", givenTitle: nil, changedAt: Date(timeIntervalSince1970: 9_280))
        // Accord's summary is as old as the change it describes; the tile's own line is as old as the tile's last activity.
        XCTAssertEqual(AgentTools.boardLine(tile, isCaller: true, summary: "Waiting on 3 subagents", fromAccord: true, record: record, now: now),
                       "- tile-1 (you) | Hardware tests | Shell | idle | ~/src | accord mac/observed-1 | Waiting on 3 subagents (12m ago)")
        XCTAssertEqual(AgentTools.boardLine(tile, isCaller: false, summary: "Running Bash", fromAccord: false, record: record, now: now),
                       "- tile-1 | Hardware tests | Shell | idle | ~/src | accord mac/observed-1 | Running Bash (1m ago)")
        // Nothing is invented for a tile Accord doesn't know or one with nothing to say.
        XCTAssertEqual(AgentTools.boardLine(tile, isCaller: false, summary: "", fromAccord: false, record: nil, now: now),
                       "- tile-1 | Hardware tests | Shell | idle | ~/src")
    }
}
