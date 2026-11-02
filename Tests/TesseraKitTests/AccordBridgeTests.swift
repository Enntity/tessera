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
        let previous = desk.typingAllowed
        defer { desk.typingAllowed = previous }
        desk.typingAllowed = true
        var typed = 0
        desk.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(desk.importAccordMessage(id: "one", text: "Check progress", from: "overseer", to: "tile", title: "Worker", wantsTyping: true))
        XCTAssertEqual(typed, 1)
        let restarted = AgentDesk(directory: dir)
        restarted.typeInto = { _, _ in typed += 1; return true }
        XCTAssertTrue(restarted.importAccordMessage(id: "one", text: "Check progress", from: "overseer", to: "tile", title: "Worker", wantsTyping: true))
        XCTAssertEqual(typed, 1)
        XCTAssertEqual(restarted.messages.count, 1)
    }
    func testCannotAcknowledgeOrTypeWhenPersistenceFails() throws {
        let file = try directory().appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: file)
        let desk = AgentDesk(directory: file)
        var typed = false
        desk.typeInto = { _, _ in typed = true; return true }
        XCTAssertFalse(desk.importAccordMessage(id: "one", text: "Check", from: "overseer", to: "tile", title: "Worker", wantsTyping: true))
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
        let previous = desk.typingAllowed
        defer { desk.typingAllowed = previous }
        desk.typingAllowed = false
        XCTAssertTrue(desk.importAccordMessage(id:"effect",text:"Check",from:"agent",to:"tile",title:"Tile",wantsTyping:true))
        desk.typeInto = { _,_ in
            let restarted = AgentDesk(directory:dir)
            XCTAssertEqual(restarted.messages.first?.delivery,"attempting")
            var replayed = false
            restarted.typeInto = { _,_ in replayed = true; return true }
            restarted.approveDelivery("accord:effect",true)
            XCTAssertFalse(replayed)
            return true
        }
        desk.approveDelivery("accord:effect",true)
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
