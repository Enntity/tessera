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
    func testOverseerProjectsOnlyOpenNonprivateEvidenceAndLinksToNativeSession() {
        let board: [String:Any] = ["sessions":[["id":"s","source":"tessera","externalId":"terminal","title":"Worker"],
            ["id":"p","source":"agent","title":"Private","private":true]],
            "incidents":[["id":"one","session_id":"s","state":"open","evidence":["kind":"quiet-session","quietMs":900000]],
                         ["id":"two","session_id":"p","state":"open"], ["id":"three","session_id":"s","state":"resolved"]]]
        let sessions = AccordBridge.projectIncidents(board,nativeIDs:["terminal"])
        XCTAssertEqual(sessions.count,1)
        XCTAssertEqual(sessions[0].link,"terminal")
        XCTAssertTrue(sessions[0].snapshot.detail?.contains("15 minutes") == true)
        XCTAssertNil(sessions[0].resumeCommand)
        XCTAssertEqual(sessions[0].snapshot.activity, .idle, "An automatic agent check-in is not a human question")
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
