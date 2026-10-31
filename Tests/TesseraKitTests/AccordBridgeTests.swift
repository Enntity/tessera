// SPDX-License-Identifier: MIT
import XCTest
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
