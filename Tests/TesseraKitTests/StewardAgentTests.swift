import Foundation
import XCTest
@testable import TesseraAPI
@testable import TesseraHost
@testable import TesseraKit

final class RedactorTests: XCTestCase {
    func testCredentialsNeverLeaveTheBoard() {
        let screen = """
            export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz012345
            curl -H "Authorization: Bearer lloom_admin_0123456789abcdef0123456789abcdef" http://head:8100
            password: hunter2hunter2
            ghp_0123456789abcdefghijABCDEFGHIJklmnop pushed to main
            commit 4f2a9c1e0b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39 is fine
            """
        let out = Redactor.redact(screen)
        for secret in ["sk-proj-abc", "0123456789abcdef0123", "hunter2", "ghp_0123"] { XCTAssertFalse(out.contains(secret), secret) }
        XCTAssertTrue(out.contains("Authorization: Bearer [secret]"))
        XCTAssertTrue(out.contains("password: [secret]"))
        // What says what a tile is doing stays.
        XCTAssertTrue(out.contains("commit 4f2a9c1e0b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39 is fine"))
        XCTAssertTrue(out.contains("pushed to main"))
    }
}

final class StewardTests: XCTestCase {
    func testCleanupSuggestionIsRecheckedAgainstLiveState() {
        var tile = TileInfo(id: "t", kind: .terminal, flavor: .shell, title: "demo", activity: .idle)
        XCTAssertTrue(Steward.canSuggestClosing(tile))
        for state in [TileActivity.working, .starting, .needsInput, .failed] {
            tile.activity = state
            XCTAssertFalse(Steward.canSuggestClosing(tile))
        }
        tile.activity = .done
        tile.attention = true
        XCTAssertFalse(Steward.canSuggestClosing(tile))
    }

    func testTitlesFoldersAndChangeNotesAreRedacted() {
        let tile = TileInfo(id: "t", kind: .terminal, flavor: .shell, title: "password=hunter2hunter2", subtitle: "token=abcdefghi", activity: .idle)
        let d = Steward.Digest(tile, text: "safe", unseen: false)
        let messages = Steward.tileMessages(d) + Steward.briefMessages([d], changes: [tile.title])
        for message in messages {
            XCTAssertFalse(message["content"]!.contains("hunter2"))
            XCTAssertFalse(message["content"]!.contains("abcdefghi"))
        }
    }

    private func completion(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func digest(_ id: String, state: String, waiting: Bool = false) -> Steward.Digest {
        Steward.Digest(id: id, title: id, kind: "terminal", flavor: "claude", subtitle: "~/src", state: state,
                       waiting: waiting, unseen: false, idleMinutes: 3, detail: nil, text: "…")
    }

    func testATileSummaryIsReadFromAFencedAnswer() throws {
        let data = completion("```json\n{\"summary\": \"running cortex unit tests\", \"blocked\": false, \"needs\": \"\"}\n```")
        let summary = try Steward.tileSummary(fromCompletion: data)
        XCTAssertEqual(summary, Steward.TileSummary(summary: "running cortex unit tests", blocked: false, needs: nil))
        XCTAssertThrowsError(try Steward.tileSummary(fromCompletion: completion("I think it is compiling.")))
    }

    func testAWantsNothingReadsAsNoNeeds() throws {
        for word in ["None.", "nothing", "n/a", "no action", "-", "NONE"] {
            let data = completion("{\"summary\": \"idling\", \"blocked\": false, \"needs\": \"\(word)\"}")
            XCTAssertNil(try Steward.tileSummary(fromCompletion: data).needs, word)
        }
        let data = completion("{\"summary\": \"idling\", \"blocked\": false, \"needs\": \"Merge when green\"}")
        XCTAssertEqual(try Steward.tileSummary(fromCompletion: data).needs, "Merge when green")
    }

    func testAnEmptyHeadlineStaysEmpty() throws {
        let data = completion("{\"headline\": \"\", \"attention\": [], \"closable\": []}")
        let brief = try Steward.brief(fromCompletion: data, digests: [digest("a", state: "idle")], changes: [])
        XCTAssertEqual(brief.headline, "")
    }

    func testTheBriefKeepsToWhatTheBoardCanStandBehind() throws {
        let digests = [digest("a", state: "idle"), digest("b", state: "working"), digest("c", state: "needsInput", waiting: true)]
        let data = completion("""
            {"headline": "Two agents busy; one asking about the migration.",
             "attention": [{"id": "c", "why": "asking which migration"}, {"id": "ghost", "why": "made up"}],
             "closable": [{"id": "a", "why": "idle shell"}, {"id": "b", "why": "looks done"}, {"id": "c", "why": "old"}, {"id": "a", "why": "again"}]}
            """)
        let brief = try Steward.brief(fromCompletion: data, digests: digests, changes: ["1 finished: x"])
        XCTAssertEqual(brief.headline, "Two agents busy; one asking about the migration.")
        XCTAssertEqual(brief.attention.map(\.id), ["c"])
        // Never a working or waiting tile, never one twice, never one it wasn't given.
        XCTAssertEqual(brief.closable.map(\.id), ["a"])
        XCTAssertEqual(brief.changes, ["1 finished: x"])
    }

    func testTheTileTextIsMarkedAsDataAndBounded() {
        let tile = TileInfo(id: "t1", kind: .terminal, flavor: .claude, title: "cortex", subtitle: "~/cortex", activity: .working)
        let long = (0..<400).map { "line \($0) token=abcdefghijk" }.joined(separator: "\n")
        let d = Steward.Digest(tile, text: long, unseen: false)
        XCTAssertLessThanOrEqual(d.text.count, 1500)
        XCTAssertTrue(d.text.hasSuffix("line 399 token=[secret]"))
        let messages = Steward.tileMessages(d)
        XCTAssertTrue(messages[0]["content"]!.contains("untrusted data"))
        XCTAssertTrue(messages[1]["content"]!.hasPrefix("<tile>"))
    }

    func testWhatHappenedWhileTheUserWasAway() {
        let away = Date().addingTimeInterval(-600)
        let tiles = [
            TileInfo(id: "1", kind: .terminal, flavor: .claude, title: "cortex", activity: .done, lastActivityAt: Date()),
            TileInfo(id: "2", kind: .terminal, flavor: .codex, title: "atlas", activity: .needsInput, lastActivityAt: Date()),
            TileInfo(id: "3", kind: .terminal, flavor: .shell, title: "old", activity: .done, lastActivityAt: away.addingTimeInterval(-60))
        ]
        XCTAssertEqual(Steward.changes(tiles, since: away), ["1 finished: cortex", "1 asking: atlas"])
    }

    func testRequestsAskForJSONFromTheConfiguredModel() throws {
        let request = try Steward.request(base: URL(string: "http://head:8100/v1")!, key: "k", model: "tessera",
                                          messages: [["role": "user", "content": "hi"]], maxTokens: 100)
        XCTAssertEqual(request.url?.absoluteString, "http://head:8100/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "tessera")
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
    }
}

/// The agent API end to end: the app's server on loopback, and the real `tessera` command.
@MainActor
final class AgentAPITests: XCTestCase {
    private var dir: URL!

    private func board() throws -> Workspace {
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-agents-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        return Workspace()
    }

    private func call(_ workspace: Workspace, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        let (status, data) = await workspace.agentTools.handle(body)
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func tool(_ workspace: Workspace, _ name: String, _ args: [String: Any], tile: String? = nil) async throws -> (String, Bool) {
        var params: [String: Any] = ["name": name, "arguments": args]
        if let tile { params["_meta"] = ["tessera/caller": ["tile": tile]] }
        let reply = try await call(workspace, "tools/call", params)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return (text, result["isError"] as? Bool ?? false)
    }

    func testMCPHandshakeAndTools() async throws {
        let workspace = try board()
        workspace.agentTools.attach(workspace)
        let hello = try await call(workspace, "initialize", ["protocolVersion": "2025-06-18"])
        let result = try XCTUnwrap(hello["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "tessera")
        let list = try await call(workspace, "tools/list")
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["board", "resources", "read_tile", "whoami", "send_message", "inbox", "ask_human", "get_answer", "notify_human"])
        let unknown = try await call(workspace, "nope")
        XCTAssertNotNil(unknown["error"])
        let malformedCaller = try await call(workspace, "tools/call", ["name": "whoami", "_meta": ["tessera/caller": "invalid scalar"]])
        XCTAssertNotNil(malformedCaller["result"])
        let (status, _) = await workspace.agentTools.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(status, 202)
    }

    func testAgentsAskTheDeveloperAndMessageEachOther() async throws {
        let workspace = try board()
        workspace.agentTools.attach(workspace)
        let page = dir.appendingPathComponent("p.html")
        try "<title>Page</title>".write(to: page, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(workspace.openBrowser(page.absoluteString))
        let b = try XCTUnwrap(workspace.openBrowser(page.absoluteString))

        let (who, _) = try await tool(workspace, "whoami", [:], tile: a)
        XCTAssertTrue(who.hasPrefix("You are tile \(a)"))

        // A question waits in the lane for its answer.
        let (pending, _) = try await tool(workspace, "ask_human", ["question": "Ship now?", "options": ["Yes", "No"], "wait_seconds": 0], tile: a)
        let id = try XCTUnwrap(pending.components(separatedBy: "Question id: ").last?.components(separatedBy: ".").first)
        let tile = AgentDesk.idPrefix + id
        XCTAssertEqual(workspace.desk.sessions.first?.id, tile)
        XCTAssertEqual(workspace.desk.choices(for: tile), ["Yes", "No"])
        workspace.desk.respond(tile, with: "Yes")
        let (answer, _) = try await tool(workspace, "get_answer", ["id": id, "wait_seconds": 0])
        XCTAssertEqual(answer, "Answer: Yes")
        XCTAssertTrue(workspace.desk.sessions.isEmpty)

        // Messages land in the recipient's inbox; only terminals can have them typed in.
        let (sent, _) = try await tool(workspace, "send_message", ["to": b, "text": "tests are red"], tile: a)
        XCTAssertTrue(sent.contains("inbox"), sent)
        let (typed, refused) = try await tool(workspace, "send_message", ["to": b, "text": "x", "type": true], tile: a)
        XCTAssertTrue(refused, typed)
        XCTAssertTrue(typed.contains("Nothing was sent"))
        let (inbox, _) = try await tool(workspace, "inbox", [:], tile: b)
        let title = try XCTUnwrap(workspace.info(a)?.title)
        XCTAssertTrue(inbox.contains("from \(title) (\(a)): tests are red"), inbox)
        let (empty, _) = try await tool(workspace, "inbox", [:], tile: b)
        XCTAssertEqual(empty, "No messages.")
        let (ambiguous, isError) = try await tool(workspace, "read_tile", ["tile": title])
        XCTAssertTrue(isError)
        XCTAssertTrue(ambiguous.contains("2 tiles are called"))

        // Privacy mode: nothing is read out.
        workspace.agentTools.privacy = { true }
        let (_, privateError) = try await tool(workspace, "read_tile", ["tile": a])
        XCTAssertTrue(privateError)
        for name in ["board", "resources", "whoami", "inbox", "get_answer"] {
            let (text, error) = try await tool(workspace, name, [:], tile: a)
            XCTAssertTrue(error, name)
            XCTAssertTrue(text.contains("privacy"), text)
        }

        // A note is a tile until seen.
        _ = try await tool(workspace, "notify_human", ["text": "Decode A/B done"], tile: a)
        let note = try XCTUnwrap(workspace.desk.sessions.first)
        XCTAssertEqual(note.snapshot.activity, .done)
        workspace.desk.seen(note.id)
        XCTAssertTrue(workspace.desk.sessions.isEmpty)
    }

    func testTheServerAndTheCommandTalkOnlyWithTheToken() async throws {
        let workspace = try board()
        workspace.agentTools.attach(workspace)
        workspace.agentServer.start()
        addTeardownBlock { @MainActor in workspace.agentServer.stop() }
        var endpoint: AgentEndpoint?
        for _ in 0..<50 where endpoint == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            endpoint = AgentEndpoint.read(from: dir)
        }
        let found = try XCTUnwrap(endpoint)
        let attributes = try FileManager.default.attributesOfItem(atPath: AgentEndpoint.file(in: dir).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        func post(token: String?, origin: String? = nil) async throws -> Int {
            var request = URLRequest(url: found.url)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            return (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
        }
        let ok = try await post(token: found.token)
        let wrong = try await post(token: "nope")
        let fromPage = try await post(token: found.token, origin: "https://evil.example")
        XCTAssertEqual([ok, wrong, fromPage], [200, 401, 403])

        // The real command, in an agent's shoes.
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("tessera-cli")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw XCTSkip("build tessera-cli first") }
        let dataDir = dir.path
        func run(_ args: [String], stdin: String? = nil) async -> (Int32, String) {
            await Task.detached {
                let process = Process()
                process.executableURL = cli
                process.arguments = args
                process.environment = ["TESSERA_DATA_DIR": dataDir, "TESSERA_AS": "test-agent", "PATH": "/usr/bin:/bin"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                if let stdin {
                    let input = Pipe()
                    process.standardInput = input
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }
                try? process.run()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }.value
        }
        let (askStatus, asked) = await run(["ask", "Merge it?", "--option", "Yes", "--wait", "0"])
        XCTAssertEqual(askStatus, 2, asked)
        let question = try XCTUnwrap(workspace.desk.questions.last)
        XCTAssertEqual(question.from, "test-agent")
        workspace.desk.respond(AgentDesk.idPrefix + question.id, with: "Yes")
        let (answerStatus, answered) = await run(["answer", question.id, "--wait", "0"])
        XCTAssertEqual(answerStatus, 0)
        XCTAssertEqual(answered.trimmingCharacters(in: .whitespacesAndNewlines), "Answer: Yes")

        let mcp = await run(["mcp"], stdin: """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"whoami","arguments":{}}}

            """)
        let lines = mcp.1.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(Set(lines.compactMap { $0["id"] as? Int }), [1, 2])
        let whoami = lines.first { $0["id"] as? Int == 2 }
        let text = (((whoami?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("You are \"test-agent\""), text)

        workspace.agentServer.stop()
        let (gone, _) = await run(["board"])
        XCTAssertEqual(gone, 3)
        let offline = await run(["mcp"], stdin: "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}\n")
        XCTAssertEqual(offline.0, 0)
        XCTAssertTrue(offline.1.contains("resources"), offline.1)
    }

    func testResourceReportDistinguishesUnconfiguredFreshAndStale() throws {
        let workspace = try board()
        XCTAssertTrue(workspace.fleet.agentReport().contains("not configured"))
        try #"{"url":"http://127.0.0.1:1"}"#.write(to: dir.appendingPathComponent("lloom.json"), atomically: true, encoding: .utf8)
        let fleet = FleetService(directory: dir)
        XCTAssertTrue(fleet.agentReport().contains("no schedule"))
        let fixture = #"{"now":1000,"resources":[{"id":"gpu","capacity":1,"holders":["r1"],"queue":["r2"]}],"reservations":[{"id":"r1","resource":"gpu","owner":"builder","state":"active","expiresAt":2000},{"id":"r2","resource":"gpu","owner":"reviewer","state":"queued"}],"jobs":[]}"#
        fleet.apply(try LLoomSchedule.parse(Data(fixture.utf8)))
        let report = fleet.agentReport()
        for value in ["fresh", "builder", "reviewer", "r1", "r2", "expires", "not a reservation"] { XCTAssertTrue(report.contains(value), report) }
        XCTAssertTrue(fleet.agentReport(now: Date().addingTimeInterval(60)).contains("STALE"))
    }
}

final class AgentRequestValidationTests: XCTestCase {
    func testMalformedLengthsNeverFormUnsafeRanges() {
        for length in ["-1", "-9223372036854775808", "999999999999999999999999", "abc", "1048577"] {
            let request = "POST /rpc HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n{}"
            XCTAssertNil(HTTPRequest(Data(request.utf8)), length)
        }
        XCTAssertNotNil(HTTPRequest(Data("POST /rpc HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)))
        XCTAssertNil(HTTPRequest(Data("POST /rpc HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
    }

    @MainActor func testUntrustedNumericArgumentsCannotTrap() {
        XCTAssertNil(AgentTools.int(Double.infinity))
        XCTAssertNil(AgentTools.int(Double.nan))
        XCTAssertNil(AgentTools.int(1e100))
        XCTAssertEqual(AgentTools.wait(-10, default: 0), 0)
        XCTAssertEqual(AgentTools.wait(100, default: 0), 55)
    }
}

/// Controlled endpoint: hold a real URLSession completion until configuration changes.
private final class HeldStewardProtocol: URLProtocol, @unchecked Sendable {
    static var started: ((HeldStewardProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?(self) }
    override func stopLoading() {}
    func complete() {
        let content = #"{"headline":"Old endpoint response","attention":[],"closable":[]}"#
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class StewardLifecycleTests: XCTestCase {
    func testLateResponseCannotRestoreDisabledSteward() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldStewardProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); HeldStewardProtocol.started = nil }
        let service = StewardService(directory: dir, session: session, readKey: { nil })
        service.digests = { [] }
        let began = expectation(description: "request reached endpoint")
        var held: HeldStewardProtocol?
        HeldStewardProtocol.started = { request in held = request; began.fulfill() }
        XCTAssertTrue(service.configure(.init(enabled: true, url: "http://steward.test/v1", model: "test"), key: nil))
        await fulfillment(of: [began], timeout: 3)
        XCTAssertTrue(service.configure(.init(enabled: false), key: nil))
        held?.complete()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(service.brief)
        XCTAssertTrue(service.summaries.isEmpty)
        XCTAssertEqual(service.status, .off)
    }
}
