// SPDX-License-Identifier: MIT
import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// End-to-end life loops against a real Accord fixture: a fake agent in a real pty records each
/// line it receives, and every wake path runs the genuine bridge-inbox → queue → bridge-unread →
/// type pipeline. Run with
/// `ACCORD_FIXTURE_CLI=/path/to/accord/src/cli.mjs swift test --filter LifeLoopE2ETests`.
/// Skips when the variable is unset (the bundled Accord predates these ops on older checkouts).
@MainActor
final class LifeLoopE2ETests: XCTestCase {
    private struct Fixture {
        var process: Process
        var directory: URL
        var dataDirectory: URL
        var profile: URL
        var agentURL: URL?
        var agent: (url: String, credential: String)?
    }

    private func fixture() async throws -> Fixture {
        guard let cli = ProcessInfo.processInfo.environment["ACCORD_FIXTURE_CLI"],
              FileManager.default.fileExists(atPath: cli) else {
            throw XCTSkip("set ACCORD_FIXTURE_CLI to a life-loops Accord cli.mjs to run")
        }
        let dir = URL(fileURLWithPath: "/tmp/tessera-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("accord-data")
        let profile = dir.appendingPathComponent("accord-connection.json")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/accord-fixture.mjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, data.path, profile.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["ACCORD_TEST_CLI": cli]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var fixture = Fixture(process: process, directory: dir, dataDirectory: data, profile: profile,
                              agentURL: URL(fileURLWithPath: profile.path + ".agent"))
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: profile.path) && process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard FileManager.default.fileExists(atPath: profile.path) else {
            throw XCTSkip("Accord fixture did not come up")
        }
        if let raw = try? Data(contentsOf: fixture.agentURL!),
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let url = json["url"] as? String, let credential = json["credential"] as? String {
            fixture.agent = (url, credential)
        }
        return fixture
    }

    /// The fake agent: prints a prompt and goes quiet (idle). While the busy flag file exists it
    /// shows a spinner line and keeps emitting output (working); removing it clears back to the
    /// prompt. Every line typed into it is appended to the log file.
    private func fakeAgent(at dir: URL) throws -> (script: URL, log: URL, busy: URL) {
        let log = dir.appendingPathComponent("agent.log")
        let busy = dir.appendingPathComponent("busy.flag")
        let script = dir.appendingPathComponent("fake-agent.sh")
        try """
        #!/bin/bash
        LOG="$1"; BUSY="$2"
        printf 'fake-agent %% '
        busy=no
        while true; do
          if [ -f "$BUSY" ]; then
            if [ "$busy" != yes ]; then printf '\\n~ working ~ esc to cancel ~\\n'; busy=yes; fi
            printf '.'
          elif [ "$busy" = yes ]; then
            printf '\\033[2J\\033[Hfake-agent %% '
            busy=no
          fi
          if IFS= read -r -t 1 line; then
            printf '%s\\n' "$line" >> "$LOG"
            printf '\\nok\\nfake-agent %% '
          fi
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log, busy)
    }

    private func lines(in log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
    }

    private func waitFor(_ timeout: TimeInterval = 30,
                         _ body: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await body()) == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// A collaboration call made as an enrolled agent (an agent owns only its own inbox).
    private func agentCall(_ fixture: Fixture, _ operation: String,
                           _ args: [String: Any] = [:], credential: String? = nil) async throws -> [String: Any] {
        let agent = try XCTUnwrap(fixture.agent)
        var request = URLRequest(url: URL(string: agent.url + "/v1/collaboration")!)
        let bearer = credential ?? agent.credential
        request.httpMethod = "POST"
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operation": operation, "args": args])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Enrolls a second agent against the fixture host (like accord-fixture.mjs does).
    private func enrollAgent(_ fixture: Fixture, label: String) async throws -> (id: String, credential: String) {
        let config = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.dataDirectory.appendingPathComponent("config.json"))) as? [String: Any]
        let authority = try XCTUnwrap(config?["authority"] as? String)
        let token = try String(contentsOf: fixture.dataDirectory.appendingPathComponent("bootstrap.token"),
                               encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try XCTUnwrap(fixture.agent?.url)
        var request = URLRequest(url: URL(string: url + "/v1/sessions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": "e2e-enroll-\(UUID().uuidString)", "label": label, "harness": "cli", "authority": authority])
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let credential = try XCTUnwrap(json["credential"] as? String)
        let id = try XCTUnwrap((json["id"] ?? json["sessionId"] ?? json["actor"]) as? String)
        return (id, credential)
    }

    private func busy(_ flag: URL, _ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: flag.path, contents: Data("busy".utf8))
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    func testLifeLoopsAgainstRealAccord() async throws {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #else
        let fixture = try await fixture()
        setenv("TESSERA_DATA_DIR", fixture.directory.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }

        let workspace = Workspace()
        workspace.isWakeableTerminalOverride = { _ in true }
        workspace.desk.wakePolicy = .overseerAndPeers
        workspace.start()
        addTeardownBlock { [workspace] in workspace.agentServer.stop() }

        let (script, log, busyFlag) = try fakeAgent(at: fixture.directory)
        let tile = workspace.launch(command: "/bin/bash '\(script.path)' '\(log.path)' '\(busyFlag.path)'")

        // The fixture's enrolled agent is this tile's agent: bind it so Accord's tileAgent picks
        // it, then wait until the tile's view exists and the binding is visible to the bridge.
        let found = try await workspace.accord.request("find", args: ["detail": true, "local": true])
        let hosts = try XCTUnwrap(found["hosts"] as? [[String: Any]])
        let authority = try XCTUnwrap(hosts[0]["authority"] as? String)
        let participants = try XCTUnwrap(hosts[0]["participants"] as? [[String: Any]])
        let agentAddress = try XCTUnwrap(participants.compactMap { $0["address"] as? String }.first {
            $0.hasPrefix(authority + "/")
        })
        let agentActor = String(agentAddress.split(separator: "/").last!)
        _ = try await workspace.accord.request("session-bind", args: [
            "key": "e2e-bind-\(tile)", "source": "tessera", "externalId": tile, "actor": agentActor])

        let ok0 = await waitFor {
            if let _ = try? await workspace.accord.request("bridge-inbox", args: ["source": "tessera", "externalId": tile]) { return true }
            return false
        }
        XCTAssertTrue(ok0, "bridge-inbox never saw the tile's view (fixture digest not reported)")

        // (a) A one-shot native-prompt schedule is typed exactly once once the tile is idle.
        _ = try await agentCall(fixture, "schedule", [
            "key": "e2e-a", "to": agentAddress, "text": "case-a wake the agent",
            "delivery": "native-prompt", "inMs": 1500])
        let ok1 = await waitFor(45) { self.lines(in: log).contains { $0.contains("case-a") } }
        if !ok1 {
            let inbox = (try? await workspace.accord.request("bridge-inbox", args: ["source": "tessera", "externalId": tile])) ?? [:]
            print("E2E-DEBUG inbox:", inbox)
            print("E2E-DEBUG desk:", workspace.desk.messages.map { [$0.id, $0.to, $0.delivery ?? "-", $0.text.prefix(60).description] })
            print("E2E-DEBUG info:", workspace.info(tile) as Any, "records:", workspace.accord.tileRecords[tile] as Any)
        }
        XCTAssertTrue(ok1, "case (a): the scheduled wake was never typed")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(lines(in: log).filter { $0.contains("case-a") }.count, 1,
                       "case (a): the wake must type exactly once")

        // (b) While the tile is busy, several fires of one schedule collapse to a single typed
        // wake: Tessera supersedes the older queued delivery by scheduleId.
        busy(busyFlag, true)
        let ok2 = await waitFor(15) { workspace.info(tile)?.activity == .working }
        XCTAssertTrue(ok2, "the fake agent never looked busy")
        _ = try await agentCall(fixture, "schedule", [
            "key": "e2e-b", "to": agentAddress, "text": "case-b interval beat",
            "delivery": "native-prompt", "on": ["event": "topic", "topic": "e2e-beat"]])
        // Accord batches topic fires roughly a minute apart, so the second delivery lands while
        // the first still sits queued on the busy tile.
        _ = try await workspace.accord.request("topic-publish", args: ["key": "e2e-b-1", "topic": "e2e-beat"])
        let ok3 = await waitFor(45) {
            workspace.desk.messages.contains { $0.to == tile && $0.text.contains("case-b") }
        }
        if !ok3 {
            print("E2E-DEBUG-b schedules:", (try? await workspace.accord.request("schedules", args: ["all": true])) ?? [:])
            print("E2E-DEBUG-b inbox:", (try? await agentCall(fixture, "inbox")) ?? [:])
            print("E2E-DEBUG-b desk:", workspace.desk.messages.map { [$0.id, $0.delivery ?? "-", $0.text.prefix(50).description] })
        }
        XCTAssertTrue(ok3, "case (b): the first fire never reached the desk")
        _ = try await workspace.accord.request("topic-publish", args: ["key": "e2e-b-2", "topic": "e2e-beat"])
        let ok4 = await waitFor(150) {
            workspace.desk.messages.filter { $0.to == tile && $0.text.contains("case-b") }.count >= 2
        }
        XCTAssertTrue(ok4, "case (b): the second fire never reached the desk")
        XCTAssertTrue(workspace.desk.messages.contains {
            $0.to == tile && $0.text.contains("case-b") && $0.delivery == "superseded"
        }, "case (b): the older queued fire was not superseded")
        busy(busyFlag, false)
        let ok5 = await waitFor(45) { self.lines(in: log).contains { $0.contains("case-b") } }
        XCTAssertTrue(ok5, "case (b): no wake was typed once the tile went idle")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(lines(in: log).filter { $0.contains("case-b") }.count, 1,
                       "case (b): repeated fires must collapse to one typed wake")

        // (c) A wake the agent reads through Accord while the tile is busy is handled, never typed.
        busy(busyFlag, true)
        let ok6 = await waitFor(15) { workspace.info(tile)?.activity == .working }
        XCTAssertTrue(ok6)
        _ = try await agentCall(fixture, "schedule", [
            "key": "e2e-c", "to": agentAddress, "text": "case-c already read",
            "delivery": "native-prompt", "inMs": 1500])
        let ok7 = await waitFor(45) {
            workspace.desk.messages.contains {
                $0.to == tile && $0.text.contains("case-c") && $0.delivery == "queued" }
        }
        XCTAssertTrue(ok7, "case (c): the fire never queued")
        let queuedC = try XCTUnwrap(workspace.desk.messages.first {
            $0.to == tile && $0.text.contains("case-c") && $0.delivery == "queued" })
        let deliveryC = String(queuedC.id.dropFirst("accord:".count))
        _ = try await agentCall(fixture, "read", ["deliveryId": deliveryC])
        busy(busyFlag, false)
        let ok8 = await waitFor(45) {
            workspace.desk.messages.first { $0.id == queuedC.id }?.delivery == "handled"
        }
        XCTAssertTrue(ok8, "case (c): the read delivery was not marked handled")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(lines(in: log).filter { $0.contains("case-c") }.count, 0,
                       "case (c): read mail must never be typed")

        // (d) The bound agent retires with a successor on the same tile: a schedule owned by the
        // retiring agent moves to the successor (as Accord's owner transfer does) and its fire is
        // retargeted, so the wake reaches the tile the successor now owns.
        _ = try await agentCall(fixture, "schedule", [
            "key": "e2e-d", "to": agentAddress, "text": "case-d successor wake",
            "delivery": "native-prompt", "inMs": 9000])
        let successor = try await enrollAgent(fixture, label: "Fixture successor")
        _ = try await agentCall(fixture, "announce",
            ["key": "e2e-announce-b", "label": "Fixture successor", "activity": "test"],
            credential: successor.credential)
        _ = try await workspace.accord.request("session-bind", args: [
            "key": "e2e-bind2-\(tile)", "source": "tessera", "externalId": tile, "actor": successor.id])
        let ok10 = await waitFor(45) { self.lines(in: log).contains { $0.contains("case-d") } }
        if !ok10 {
            print("E2E-DEBUG-d schedules:", (try? await workspace.accord.request("schedules", args: ["all": true])) ?? [:])
            print("E2E-DEBUG-d inboxB:", (try? await agentCall(fixture, "inbox", credential: successor.credential)) ?? [:])
            print("E2E-DEBUG-d desk:", workspace.desk.messages.map { [$0.id, $0.delivery ?? "-", $0.text.prefix(50).description] })
            print("E2E-DEBUG-d records:", workspace.accord.tileRecords[tile] as Any)
        }
        XCTAssertTrue(ok10, "case (d): the wake never reached the successor's tile")
        let ok11 = await waitFor(15) {
            workspace.accord.tileRecords[tile]?.agentAddress == authority + "/" + successor.id
        }
        XCTAssertTrue(ok11, "case (d): the tile record never moved to the successor")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(lines(in: log).filter { $0.contains("case-d") }.count, 1)

        // (e) A queued wake survives a Tessera restart: a fresh Workspace on the same state
        // directory loads the queue and types it once, never twice.
        busy(busyFlag, true)
        let ok12 = await waitFor(15) { workspace.info(tile)?.activity == .working }
        XCTAssertTrue(ok12)
        _ = try await agentCall(fixture, "schedule", [
            "key": "e2e-e", "to": authority + "/" + successor.id, "text": "case-e restart wake",
            "delivery": "native-prompt", "inMs": 1500], credential: successor.credential)
        let ok13 = await waitFor(45) {
            workspace.desk.messages.contains {
                $0.to == tile && $0.text.contains("case-e") && $0.delivery == "queued" }
        }
        XCTAssertTrue(ok13, "case (e): the fire never queued")

        let restarted = Workspace()
        XCTAssertTrue(restarted.desk.messages.contains {
            $0.to == tile && $0.text.contains("case-e") && $0.delivery == "queued"
        }, "case (e): the queued wake did not survive in accord-desk.json")
        // The first workspace's copy of the message is handled so only the restarted queue can
        // type; its own tile stays busy for the rest of the test.
        if let queuedE = workspace.desk.messages.first(where: {
            $0.to == tile && $0.text.contains("case-e") && $0.delivery == "queued" }) {
            workspace.desk.markHandled(queuedE.id)
        }
        restarted.isWakeableTerminalOverride = { _ in true }
        restarted.desk.wakePolicy = .overseerAndPeers
        restarted.desk.typeInto = { id, text in restarted.typeMessage(text, into: id) }
        let busy2 = fixture.directory.appendingPathComponent("busy2.flag")
        let resumed = TerminalSession(id: tile,
            command: "/bin/bash '\(script.path)' '\(log.path)' '\(busy2.path)'", cwd: fixture.directory.path)
        restarted.adopt(resumed)
        let ok14 = await waitFor(45) {
            restarted.pumpWakes()
            return self.lines(in: log).contains { $0.contains("case-e") }
        }
        XCTAssertTrue(ok14, "case (e): the restarted workspace never typed the queued wake")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(lines(in: log).filter { $0.contains("case-e") }.count, 1,
                       "case (e): a restarted queue must not double-type")
        #endif
    }
}
