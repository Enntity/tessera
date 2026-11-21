// SPDX-License-Identifier: MIT
import XCTest
import TesseraKit
@testable import TesseraHost

@MainActor
final class AccordBridgeTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accord-desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDeliverySurvivesRestartAndDoesNotRetype() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed = 0
        desk.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Check progress", from: "overseer", address: nil, tile: nil,
                                       to: "tile", title: "Worker", route: .queued))
        // Queued is not typed on the spot: the pump types it once the tile sits idle.
        XCTAssertEqual(desk.messages.first?.delivery, "queued")
        XCTAssertEqual(typed, 0)
        XCTAssertTrue(desk.deliverQueued("tile"))
        XCTAssertEqual(typed, 1)
        let restarted = AgentDesk(directory: dir)
        restarted.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(restarted.importMessage(id: "accord:one", text: "Check progress", from: "overseer", address: nil, tile: nil,
                                            to: "tile", title: "Worker", route: .queued))
        XCTAssertEqual(typed, 1)
        XCTAssertEqual(restarted.messages.count, 1)
    }
    func testCannotAcknowledgeOrTypeWhenPersistenceFails() throws {
        let file = try directory().appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: file)
        let desk = AgentDesk(directory: file)
        var typed = false
        desk.typeInto = { _, _ in typed = true; return true }
        XCTAssertFalse(desk.importMessage(id: "accord:one", text: "Check", from: "overseer", address: nil, tile: nil,
                                        to: "tile", title: "Worker", route: .queued))
        XCTAssertFalse(typed)
        XCTAssertTrue(desk.messages.isEmpty)
    }
    func testQuestionImportAndAnswerRoundTrip() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        let questions: [[String: Any]] = [["id": "one", "question": "Choose a target", "options": "[\"A\",\"B\"]"]]
        desk.importAccordQuestions(questions); desk.importAccordQuestions(questions)
        XCTAssertEqual(desk.questions.count, 1)
        desk.answer("accord:one", with: "B")
        let restarted = AgentDesk(directory: dir)
        XCTAssertEqual(restarted.accordAnswers().first?.0, "one")
        XCTAssertEqual(restarted.accordAnswers().first?.1, "B")
    }
}

extension AccordBridgeTests {
    func testProjectionExcludesPrivateAndNativeDuplicatesAndNeverOffersExecution() {
        let sessions: [[String: Any]] = [
            ["address":"local/one","source":"codex","externalId":"native","title":"Native","state":"working"],
            ["address":"local/two","source":"agent","title":"Private","private":true],
            ["address":"remote/three","source":"agent","title":"Remote","state":"blocked","detail":"Needs a target","progressAt":1000.0],
            ["address":"local/four","source":"tessera","externalId":"accord:remote/three","title":"Loop","state":"working"]
        ]
        let projected = AccordBridge.project(["authority":"local","sessions":sessions], nativeIDs: ["codex:native"])
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].id, "accord:remote/three")
        XCTAssertEqual(projected[0].snapshot.activity, .needsInput)
        XCTAssertNil(projected[0].resumeCommand)
        XCTAssertNil(projected[0].openURL)
    }
}

extension AccordBridgeTests {
    func testOldDeskIsPreservedWithoutReactivatingSessions() throws {
        let dir = try directory()
        let original = Data("saved pre-Accord user data".utf8)
        let old = dir.appendingPathComponent("agent-desk.json")
        try original.write(to:old)
        let desk = AgentDesk(directory:dir)
        XCTAssertTrue(desk.sessions.isEmpty)
        desk.importAccordQuestions([["id":"new","question":"New question"]])
        XCTAssertEqual(try Data(contentsOf:old),original)
        XCTAssertEqual(AgentDesk(directory:dir).questions.count,1)
    }
    func testPromptAttemptIsPersistedBeforeNativeInput() throws {
        let dir = try directory(), desk = AgentDesk(directory:dir)
        XCTAssertTrue(desk.importMessage(id:"accord:effect",text:"Check",from:"agent",address:nil,tile:nil,to:"tile",title:"Tile",route:.queued))
        desk.typeInto = { _,_ in
            let restarted = AgentDesk(directory:dir)
            XCTAssertEqual(restarted.messages.first?.delivery,"attempting")
            var replayed = false
            restarted.typeInto = { _,_ in replayed = true; return true }
            // An uncertain attempt is never replayed, even as the queue moves on.
            restarted.deliverQueued("tile")
            XCTAssertFalse(replayed)
            return true
        }
        desk.deliverQueued("tile")
        XCTAssertEqual(desk.messages.first?.delivery,"typed")
    }
}

extension AccordBridgeTests {
    func testFleetProjectionKeepsDelegatedQueuesJobsAndUnknownOwnership() throws {
        let remote: [String:Any] = ["name":"fleet","board":["resources":[["id":"gpu","holders":["r1"],"queue":["r2"]]],
            "reservations":[["id":"r1","resource":"gpu","owner":"worker","state":"active","expiresAt":2000]],
            "jobs":[["id":"job","title":"Serving","owner":"worker","state":"running","startedAt":1000,"heartbeatAt":1500,"notes":[],"metrics":["tokens":10]]]]]
        let native: [String:Any] = ["id":"host/gpu","state":"unknown","queue":[["id":"waiting"]]]
        let board = try FleetService.project(resources:[native],jobs:[],managers:[remote])
        XCTAssertEqual(board.resources[0].holders,["fleet:r1"])
        XCTAssertEqual(board.resources[0].queue,["fleet:r2"])
        XCTAssertEqual(board.reservations[0].resource,"fleet:gpu")
        XCTAssertEqual(board.jobs[0].id,"fleet:job")
        XCTAssertNotNil(board.resources[1].error)
        XCTAssertEqual(board.resources[1].queue,["waiting"])
    }
}

extension AccordBridgeTests {
    func testSharedBoardKeepsLastSnapshotOnFailuresAndDoesNotPromoteCheckinsOrOldSessions() {
        let bridge = AccordBridge(), now = Date(timeIntervalSince1970:10000)
        let session: [String:Any] = ["address":"remote/live","source":"agent","title":"Training","state":"working","progressAt":9990000.0,"summary":"Evaluating checkpoint"]
        let board: [String:Any] = ["authority":"local","sessions":[session,
            ["address":"local/old","source":"agent","title":"Old","state":"working","progressAt":1.0],
            ["address":"local/exited","source":"agent","title":"Ended","state":"exited"]],
            "incidents":[["id":"ping","state":"open","session_id":"live"]]]
        bridge.acceptSnapshot(board,nativeIDs:[],now:now)
        XCTAssertEqual(bridge.projectedSessions.count,1)
        XCTAssertEqual(bridge.projectedSessions[0].snapshot.items[0].role,.assistant)
        XCTAssertEqual(bridge.projectedSessions[0].snapshot.items[0].text,"Agent report at 1970-01-01T02:46:30Z: Evaluating checkpoint")
        let before = bridge.projectedSessions
        bridge.connectionFailed()
        XCTAssertEqual(bridge.projectedSessions,before)
        bridge.acceptSnapshot(["sessions":[],"hosts":[["authority":"remote","status":"unknown"]]],nativeIDs:[],now:now)
        XCTAssertEqual(bridge.projectedSessions,before)
        bridge.acceptSnapshot(["sessions":[],"hosts":[["authority":"remote","status":"observed"]]],nativeIDs:[],now:now)
        XCTAssertTrue(bridge.projectedSessions.isEmpty)
        XCTAssertEqual(AccordBridge.project(board,nativeIDs:[],includeNativeHistory:true).count,3)
    }
    func testFinishedAndFailedSharedSessionsReachTheBoardButDeadOnesDoNot() {
        let board: [String:Any] = ["authority":"local","sessions":[
            ["address":"local/done","source":"agent","title":"Finished result","state":"done","progressAt":9990000.0],
            ["address":"local/failed","source":"agent","title":"Failed run","state":"failed","progressAt":9990000.0],
            ["address":"local/olddone","source":"agent","title":"Stale result","state":"done","progressAt":1000000.0],
            ["address":"local/exited","source":"agent","title":"Ended","state":"exited","progressAt":9990000.0],
            ["address":"local/cancelled","source":"agent","title":"Stopped","state":"cancelled","progressAt":9990000.0]]]
        let sessions = AccordBridge.project(board,nativeIDs:[],lookback:3600,now:Date(timeIntervalSince1970:10000))
        XCTAssertEqual(sessions.map(\.title),["Finished result","Failed run"])
        XCTAssertEqual(sessions[0].snapshot.activity,.done)
        XCTAssertEqual(sessions[1].snapshot.activity,.failed)
    }
    func testBoundAgentDoesNotDuplicateNativeTile() {
        let row: [String:Any] = ["address":"local/agent","source":"agent","title":"Worker","state":"working","progressAt":9990000.0,"nativeSession":["source":"codex","externalId":"thread"]]
        XCTAssertTrue(AccordBridge.project(["authority":"local","sessions":[row]],nativeIDs:["codex:thread"],now:Date(timeIntervalSince1970:10000)).isEmpty)
    }
}

@MainActor final class PairingIsolationTests: XCTestCase {
    func testDisabledPhoneLinkNeverReadsOrWritesKeychain() throws {
        let previous = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-isolation-" + UUID().uuidString)
        setenv("TESSERA_DATA_DIR",directory.path,1)
        defer {
            if let previous { setenv("TESSERA_DATA_DIR",previous,1) } else { unsetenv("TESSERA_DATA_DIR") }
            try? FileManager.default.removeItem(at:directory)
        }
        var reads = 0, writes = 0
        let server = HostServer(workspace:Workspace(),open:{ _ in },close:{ _ in },readCode:{ reads += 1; return nil },saveCode:{ _ in writes += 1 })
        XCTAssertEqual(reads,0); XCTAssertEqual(writes,0)
        XCTAssertNil(server.pairingURL)
        server.stop()
        XCTAssertEqual(reads,0); XCTAssertEqual(writes,0)
        server.preparePairingCode()
        XCTAssertEqual(reads,1); XCTAssertEqual(writes,1)
        server.preparePairingCode()
        XCTAssertEqual(reads,1); XCTAssertEqual(writes,1)
    }
    func testDeniedPairingReadNeverOverwritesSavedCode() {
        let previous = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-denied-" + UUID().uuidString)
        setenv("TESSERA_DATA_DIR",directory.path,1)
        defer {
            if let previous { setenv("TESSERA_DATA_DIR",previous,1) } else { unsetenv("TESSERA_DATA_DIR") }
            try? FileManager.default.removeItem(at:directory)
        }
        var writes = 0
        let server = HostServer(workspace:Workspace(),open:{ _ in },close:{ _ in },readCode:{ throw URLError(.userAuthenticationRequired) },saveCode:{ _ in writes += 1 })
        server.preparePairingCode()
        XCTAssertFalse(server.pairingCode.isEmpty)
        XCTAssertEqual(writes,0)
    }
}

extension AccordBridgeTests {
    func testFleetKeepsResourcesFromPeerWithPrivateJobs() async throws {
        let fleet = try await FleetService.nativeFleet(hosts: [["authority": "mini"], ["authority": "spark"]]) { operation, host in
            if operation == "resources" { return ["resources": [["id": host + "/machine"]]] }
            if host == "mini" { throw AccordRequestError.activityNotShared }
            return ["jobs": [["id": "serving"]]]
        }
        XCTAssertEqual(fleet.resources.compactMap { $0["id"] as? String }, ["mini/machine", "spark/machine"])
        XCTAssertEqual(fleet.jobs.compactMap { $0["id"] as? String }, ["spark/serving"])
    }

    func testFleetStillSurfacesUnexpectedJobErrors() async {
        do {
            _ = try await FleetService.nativeFleet(hosts: [["authority": "mini"]]) { operation, _ in
                if operation == "jobs" { throw URLError(.cannotConnectToHost) }
                return ["resources": []]
            }
            XCTFail("A disconnected peer must report a stale fleet")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testMigratedFleetReadsNativeResourcesAcrossAuthorities() async throws {
        XCTAssertTrue(FleetService.managersReachable([["state":"migrated"], ["state":"observed"]]))
        XCTAssertFalse(FleetService.managersReachable([["state":"unknown"]]))
        let fleet = try await FleetService.nativeFleet(hosts:[["authority":"mac"], ["authority":"spark"], ["authority":"spark"]]) { operation, host in
            if operation == "resources" { return ["resources":[["id":host+"/gpu", "label":"GPU", "state":"unknown"]]] }
            return ["jobs":[["id":"same", "title":"Serving", "state":"working"]]]
        }
        XCTAssertEqual(fleet.resources.count,2)
        let board = try FleetService.project(resources:fleet.resources, jobs:fleet.jobs, managers:[["name":"lloom", "state":"migrated"]])
        XCTAssertEqual(board.resources.map(\.id),["mac/gpu","spark/gpu"])
        XCTAssertEqual(LLoomSchedule.lanes(board).map(\.label),["GPU","GPU"])
        XCTAssertEqual(Set(board.jobs.map(\.id)),Set(["accord:mac/same","accord:spark/same"]))
        XCTAssertTrue(board.resources.allSatisfy { $0.error != nil })
    }
}

extension AccordBridgeTests {
    func testNativeCLIAliasSuppressesDesktopDuplicateAndParentLinkIsPreserved() {
        let now=Date(timeIntervalSince1970:10000)
        let base:[String:Any] = ["source":"claude","state":"working","progressAt":9990000.0]
        let native=base.merging(["address":"local/native","externalId":"cli-id","title":"Main task"]) { _,b in b }
        let child=base.merging(["address":"local/child","externalId":"cli-id/agent-1","title":"Review","parentSession":["source":"claude","externalId":"cli-id"]]) { _,b in b }
        let proxy:[String:Any] = ["address":"remote/proxy","source":"agent","title":"Resource holder","state":"working","progressAt":9990000.0,"originAddress":"local/owner"]
        let projected=AccordBridge.project(["authority":"local","sessions":[native,child,proxy]],nativeIDs:["claude:local-desktop","claude:cli-id"],now:now)
        XCTAssertEqual(projected.map(\.id),["accord:local/child"])
        XCTAssertEqual(projected.first?.link,"claude:cli-id")
        XCTAssertTrue(AccordBridge.project(["authority":"other","sessions":[child]],nativeIDs:[],now:now).first?.link?.hasPrefix("accord:local/observed-") == true)
    }
    func testTaskMRUUsesDeliberateOpensAndStableTies() {
        let ids=["old","new","tie"]
        let times=["old":Date(timeIntervalSince1970:1),"new":Date(timeIntervalSince1970:2),"tie":Date(timeIntervalSince1970:2)]
        XCTAssertEqual(Workspace.taskOrder(ids,recent:[],activity:times),["new","tie","old"])
        XCTAssertEqual(Workspace.taskOrder(ids,recent:["old"],activity:times),["old","new","tie"])
        XCTAssertEqual(Workspace.taskOrder(ids,recent:["old","old"],activity:times),["old","new","tie"])
    }
}


extension AccordBridgeTests {
    func testCachedSearchCannotOverrideNewerLiveState() {
        func tile(_ title: String, _ state: TileActivity, _ time: Double) -> AgentAppSession {
            AgentAppSession(id: "accord:host/music", flavor: .accord, title: title, cwd: "", openURL: nil, resumeCommand: nil,
                snapshot: ConversationSnapshot(items: [], activity: state), lastActivityAt: Date(timeIntervalSince1970: time))
        }
        let old = tile("No resources reserved", .needsInput, 10), live = tile("Comparing music", .working, 20)
        let sources = ["accord-search": [old.id: old], "accord": [live.id: live]]
        XCTAssertEqual(AgentAppWatcher.mergeSessions(scanned: [:], external: sources)[live.id], live)
        let done = tile("Finished", .done, 20)
        XCTAssertEqual(AgentAppWatcher.mergeSessions(scanned: [:], external: ["accord-search": [live.id: live], "accord": [done.id: done]])[done.id], done)
    }
    func testOpenedHistoryReceivesCompletionAndWaitingIsNotAQuestion() {
        let bridge = AccordBridge(), now = Date(timeIntervalSince1970: 100)
        bridge.retainedSessionIDs = ["accord:host/music"]
        let waiting: [String: Any] = ["address":"host/music", "source":"agent", "title":"Waiting for a collaborator", "state":"waiting", "detail":"No resources reserved", "progressAt":99000.0]
        bridge.acceptSnapshot(["authority":"host", "sessions":[waiting]], nativeIDs: [], now:now)
        XCTAssertEqual(bridge.projectedSessions.first?.snapshot.activity, .idle)
        XCTAssertTrue(bridge.projectedSessions.first?.snapshot.detail?.hasPrefix("Agent report at ") == true)
        var done = waiting; done["state"] = "done"; done["title"] = "Finished"; done["progressAt"] = 100000.0
        bridge.acceptSnapshot(["authority":"host", "sessions":[done]], nativeIDs: [], now:now)
        XCTAssertEqual(bridge.projectedSessions.first?.title, "Finished")
        XCTAssertEqual(bridge.projectedSessions.first?.snapshot.activity, .done)
    }
}

extension AccordBridgeTests {
    func testNativeLeaseRecoveryIsNotFailureAndUnknownOwnershipStaysHeld() throws {
        for state in ["running", "preparing", "releasing", "revoking", "recovering", "future-state", ""] {
            let resource: [String:Any] = ["id":"host/gpu", "label":"Spark pair", "state":"held",
                "holder":["claim":"lease", "label":"worker", "state":state, "deadline":2000]]
            let board = try FleetService.project(resources:[resource],jobs:[],managers:[])
            XCTAssertTrue(LLoomSchedule.items(board,lookback:3600).isEmpty, state)
            let lane = try XCTUnwrap(LLoomSchedule.lanes(board).first)
            XCTAssertNotEqual(lane.state,.free, state)
            XCTAssertEqual(lane.holders,["worker"])
            if ["future-state", ""].contains(state) { XCTAssertEqual(lane.state,.unusable) }
            if ["revoking", "recovering", "releasing"].contains(state) { XCTAssertEqual(lane.state,.attention) }
        }
    }
    func testActualLeaseFailureHasReadableNameBodyAndHonestTime() throws {
        var holder: [String:Any] = ["claim":"lease", "label":"worker", "state":"stuck", "error":"Host unreachable", "address":"host/worker"]
        func project() throws -> LLoomSchedule.Item {
            let resource: [String:Any] = ["id":"host/opaque-id", "label":"Spark pair", "hosts":["spark01","spark02"], "state":"held", "holder":holder]
            return try XCTUnwrap(LLoomSchedule.items(FleetService.project(resources:[resource],jobs:[],managers:[]),lookback:3600).first)
        }
        let unknown = try project()
        XCTAssertEqual(unknown.title,"Spark pair restore failed")
        XCTAssertEqual(unknown.activity,.failed)
        XCTAssertEqual(unknown.lastActivityAt.shortAge(),"unknown")
        XCTAssertNil(unknown.notes.first?.timestamp)
        XCTAssertEqual(unknown.notes.first?.role,.assistant)
        XCTAssertTrue(unknown.notes.first?.text.contains("Host unreachable") == true)
        XCTAssertTrue(unknown.notes.first?.text.contains("spark01, spark02") == true)
        XCTAssertTrue(unknown.notes.first?.text.contains("Update time unavailable") == true)
        XCTAssertFalse(FleetService.session(unknown).snapshot.items.isEmpty)
        XCTAssertEqual(unknown.session,"accord:host/worker")
        holder["updatedAt"] = 1793600000000.0
        let dated = try project()
        XCTAssertEqual(dated.changedAt,Date(timeIntervalSince1970:1793600000))
        XCTAssertEqual(dated.notes.first?.timestamp,dated.changedAt)
    }
}

extension AccordBridgeTests {
    private func digest(_ id: String, title: String, idleMinutes: Int = 0) -> Steward.Digest {
        Steward.Digest(id: id, title: title, kind: "terminal", flavor: "shell", subtitle: "~/work", state: "working",
                       waiting: false, unseen: false, idleMinutes: idleMinutes, detail: "Compiling", text: "Fixture observation")
    }

    /// An active tile reports no progress time: Accord's own now is right, and a coordinator a
    /// fraction behind our clock rejects ours. Idle tiles still send their progress time.
    func testReportArgsOnlySendsProgressForIdleTiles() {
        let active = AccordBridge.reportArgs(digest("tile-a", title: "Working"), key: "k", nowMs: 1_000_000)
        XCTAssertNil(active["sourceProgressAt"])
        XCTAssertEqual(active["externalId"] as? String, "tile-a")
        XCTAssertEqual(active["title"] as? String, "Working")
        XCTAssertEqual(active["state"] as? String, "working")
        XCTAssertEqual((active["events"] as? [[String: Any]])?.count, 1)
        let idle = AccordBridge.reportArgs(digest("tile-b", title: "Idle", idleMinutes: 3), key: "k", nowMs: 1_000_000)
        XCTAssertEqual(idle["sourceProgressAt"] as? Int, 1_000_000 - 3 * 60000)
    }

    /// One report Accord rejects (an empty title is a guaranteed 400) must not stall the pass:
    /// the next digest is still published and the board read still happens.
    func testARejectedReportDoesNotStallTheRefresh() async throws {
        // Under /tmp like the packaged tests: the bundled Accord's local socket can't take a
        // /var/folders data path.
        let dir = URL(fileURLWithPath: "/tmp/accord-bridge-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/accord-fixture.mjs")
        let profile = dir.appendingPathComponent("accord-connection.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, dir.appendingPathComponent("accord-data").path, profile.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: profile.path) && process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let bridge = AccordBridge(profile: profile)
        bridge.digests = { [self] in [digest("bad-tile", title: ""), digest("good-tile", title: "Good tile")] }
        await bridge.refresh()
        XCTAssertTrue(bridge.connected)
        // The good tile was reported and read back even though the first digest was refused.
        let record = try XCTUnwrap(bridge.tileRecords["good-tile"])
        XCTAssertNil(record.givenTitle)
        try await agentOperation(dir, "session-title", ["key": "title-1", "source": "tessera", "externalId": "good-tile", "title": "Fixture given name"])
        await bridge.refresh()
        XCTAssertTrue(bridge.connected)
        XCTAssertEqual(bridge.tileRecords["good-tile"]?.givenTitle, "Fixture given name")
    }

    private func agentOperation(_ dir: URL, _ operation: String, _ args: [String: Any]) async throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("accord-connection.json.agent"))
        let agent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        var request = URLRequest(url: URL(string: agent["url"]! + "/v1/collaboration")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + agent["credential"]!, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operation": operation, "args": args])
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

extension AccordBridgeTests {
    /// A queued delivery is typed in order, one per pass: the tile goes to work after the first,
    /// so the next waits for it to sit idle again.
    func testQueuedDeliveriesTypeInOrderOnePerPass() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed: [String] = []
        desk.typeInto = { _, text in typed.append(text); return true }
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "First", from: "Tessera", address: "mac/obs-1", tile: "over",
                                       to: "tile", title: "Worker", route: .queued))
        XCTAssertTrue(desk.importMessage(id: "accord:two", text: "Second", from: "Tessera", address: "mac/obs-1", tile: "over",
                                       to: "tile", title: "Worker", route: .queued))
        XCTAssertEqual(desk.queuedTiles, ["tile"])
        desk.deliverQueued("tile")
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(desk.messages.map(\.delivery), ["typed", "queued"])
        desk.deliverQueued("tile")
        XCTAssertEqual(typed.count, 2)
        // The first typed carries who sent it, where to answer, and how to acknowledge.
        XCTAssertEqual(typed.first, "[Message from Tessera via Accord; reply with accord_send to mac/obs-1; accord_read one once handled] First")
    }

    /// A local send types the same message without Accord's reply/read instructions.
    func testALocalSendIsTypedWithoutAccordMachinery() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed: [String] = []
        desk.typeInto = { _, text in typed.append(text); return true }
        XCTAssertTrue(desk.importMessage(id: "local:abc", text: "Look at tests", from: "Builder", address: nil, tile: "from-tile",
                                       to: "tile", title: "Worker", route: .queued))
        desk.deliverQueued("tile")
        XCTAssertEqual(typed, ["[Message from Builder via Tessera] Look at tests"])
    }

    /// "Deliver" on a waiting card queues it for idle; it is never typed on the spot.
    func testDeliverOnAWaitingCardQueuesNotTypes() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed = 0
        desk.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Check", from: "agent", address: "mac/a", tile: nil,
                                       to: "tile", title: "Tile", route: .ask))
        XCTAssertEqual(desk.choices(for: "ask:accord:one"), ["Deliver", "Don't"])
        desk.respond("ask:accord:one", with: "Deliver")
        XCTAssertEqual(desk.messages.first?.delivery, "queued")
        XCTAssertEqual(typed, 0)
        desk.deliverQueued("tile")
        XCTAssertEqual(typed, 1)
    }

    /// A queued delivery survives a restart as queued — it still types when the tile is ready.
    func testARestartKeepsWhatIsQueued() throws {
        let dir = try directory()
        let desk = AgentDesk(directory: dir)
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Check", from: "agent", address: nil, tile: nil,
                                       to: "tile", title: "Tile", route: .queued))
        let restarted = AgentDesk(directory: dir)
        XCTAssertEqual(restarted.messages.first?.delivery, "queued")
        XCTAssertEqual(restarted.queuedTiles, ["tile"])
        var typed = false
        restarted.typeInto = { _, _ in typed = true; return true }
        restarted.deliverQueued("tile")
        XCTAssertTrue(typed)
    }

    /// A tile that is gone fails its queue, so the "Check delivery" card tells the user.
    func testAGoneTileFailsItsQueue() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Check", from: "agent", address: nil, tile: nil,
                                       to: "gone", title: "Gone", route: .queued))
        desk.failQueued("gone")
        XCTAssertEqual(desk.messages.first?.delivery, "failed")
        XCTAssertTrue(desk.sessions.contains { $0.snapshot.activity == .needsInput && $0.title.contains("Check delivery") })
    }

    /// A queued message that outlives the desk's keep window fails rather than typing a day late.
    func testAQueuedMessageLeftForADayFailsInsteadOfTypingLate() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed = 0
        desk.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(desk.importMessage(id: "local:old", text: "Check", from: "agent", address: nil, tile: nil,
                                       to: "tile", title: "Worker", route: .queued, at: Date().addingTimeInterval(-90000)))
        desk.expireQueued()
        XCTAssertEqual(desk.messages.first?.delivery, "failed")
        XCTAssertFalse(desk.deliverQueued("tile"))
        XCTAssertEqual(typed, 0)
    }

    /// Done-with messages of any origin age out; a card still waiting for the user, or a message
    /// still queued or failed, keeps its place no matter how old.
    func testFinishedMessagesAgeOutWhateverTheirOrigin() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        desk.typeInto = { _, _ in true }
        let old = Date().addingTimeInterval(-90000)
        XCTAssertTrue(desk.importMessage(id: "local:done", text: "x", from: "o", address: nil, tile: nil,
                                       to: "tile", title: "W", route: .queued, at: old))
        desk.deliverQueued("tile")
        XCTAssertTrue(desk.messages.isEmpty)
        XCTAssertTrue(desk.importMessage(id: "accord:wait", text: "x", from: "o", address: nil, tile: nil,
                                       to: "tile", title: "W", route: .ask, at: old))
        XCTAssertTrue(desk.importMessage(id: "local:held", text: "x", from: "o", address: nil, tile: nil,
                                       to: "tile", title: "W", route: .queued, at: old))
        desk.expireQueued()
        XCTAssertEqual(desk.messages.map(\.delivery), ["waiting", "failed"])
    }

    /// A message for a conversation in a desktop app is offered to open with the text copied —
    /// never typed anywhere.
    func testAnAppConversationIsOpenedWithTheTextCopied() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        var typed = 0, opened: (tile: String, text: String)?
        desk.typeInto = { _, _ in typed += 1; return true }
        desk.openWithText = { tile, text in opened = (tile, text); return true }
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Summarize the board", from: "Tessera", address: "mac/obs", tile: nil,
                                       to: "app-tile", title: "Claude", route: .open))
        XCTAssertEqual(desk.choices(for: "ask:accord:one"), ["Open and Copy", "Dismiss"])
        desk.respond("ask:accord:one", with: "Open and Copy")
        XCTAssertEqual(opened?.tile, "app-tile")
        XCTAssertEqual(opened?.text, "[Message from Tessera via Accord; reply with accord_send to mac/obs; accord_read one once handled] Summarize the board")
        XCTAssertEqual(desk.messages.first?.delivery, "opened")
        XCTAssertEqual(typed, 0)
    }

    /// The tile-card mark: pending states while they last, delivered ones for an hour.
    func testTheWakeMarkTracksTheLatestMessage() throws {
        let dir = try directory(), desk = AgentDesk(directory: dir)
        XCTAssertNil(desk.wakeMark(for: "tile"))
        XCTAssertTrue(desk.importMessage(id: "accord:one", text: "Check", from: "Tessera", address: nil, tile: nil,
                                       to: "tile", title: "Tile", route: .queued))
        XCTAssertEqual(desk.wakeMark(for: "tile")?.state, .queued)
        desk.typeInto = { _, _ in true }
        desk.deliverQueued("tile")
        let mark = try XCTUnwrap(desk.wakeMark(for: "tile"))
        XCTAssertEqual(mark.state, .typed)
        XCTAssertEqual(mark.from, "Tessera")
        XCTAssertNil(desk.wakeMark(for: "tile", now: Date().addingTimeInterval(3700)))
    }

    /// A tile kept out of waking stays out until let back in, and survives a restart.
    func testThePerTileOptOutPersists() throws {
        let dir = try directory()
        let desk = AgentDesk(directory: dir)
        desk.setNoWake("tile", true)
        XCTAssertTrue(AgentDesk(directory: dir).noWake.contains("tile"))
        desk.setNoWake("tile", false)
        XCTAssertFalse(AgentDesk(directory: dir).noWake.contains("tile"))
    }
}

extension AccordBridgeTests {
    /// Where a sender lives on this board: a tessera session's own tile, or the native
    /// conversation its binding names (the overseer's is claude/<its session id>). Sessions
    /// from other authorities never map.
    func testSenderTilesResolveLocalNativeBindings() {
        let sessions: [[String: Any]] = [
            ["address": "mac/tile-session", "source": "tessera", "externalId": "tile-1", "title": "t"],
            ["address": "mac/overseer", "source": "claude", "title": "over",
             "nativeSession": ["source": "claude", "externalId": "session-9"]],
            ["address": "mac/direct", "source": "agent", "title": "d",
             "nativeSession": ["source": "tessera", "externalId": "tile-2"]],
            ["address": "remote/other", "source": "agent", "title": "r",
             "nativeSession": ["source": "claude", "externalId": "far"]],
            ["address": "mac/plain", "source": "agent", "title": "p"]
        ]
        XCTAssertEqual(AccordBridge.senderTiles(sessions, authority: "mac"),
                       ["mac/tile-session": "tile-1", "mac/overseer": "claude:session-9", "mac/direct": "tile-2"])
    }
}
