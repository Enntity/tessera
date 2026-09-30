import libzstd
import XCTest
@testable import TesseraHost
@testable import TesseraKit

final class ZstdTailTests: XCTestCase {
    private func frame(_ text: String) -> Data {
        let src = Array(text.utf8)
        var dst = [UInt8](repeating: 0, count: ZSTD_compressBound(src.count))
        let n = ZSTD_compress(&dst, dst.count, src, src.count, 3)
        return Data(dst[0..<n])
    }

    /// A frame with a content checksum; damaging it keeps the structure but fails decoding.
    private func checkedFrame(_ text: String) -> Data {
        let src = Array(text.utf8)
        var dst = [UInt8](repeating: 0, count: ZSTD_compressBound(src.count))
        let cctx = ZSTD_createCCtx()
        defer { ZSTD_freeCCtx(cctx) }
        ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, 1)
        let n = ZSTD_compress2(cctx, &dst, dst.count, src, src.count)
        return Data(dst[0..<n])
    }

    /// Damage in the middle of a log costs only the damaged part: nothing repeats, nothing stalls.
    func testDamagedFramesAreSkipped() throws {
        var bad = checkedFrame("{\"bad\":1}\n")
        bad[bad.count - 1] ^= 0xFF
        let data = frame("{\"a\":1}\n") + bad + Data("not zstd".utf8) + frame("{\"c\":3}\n")
        let (decoded, consumed) = ZstdTail.decodeCompleteFrames(data)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "{\"a\":1}\n{\"c\":3}\n")
        XCTAssertEqual(consumed, data.count)
        // Garbage at the end may be a frame still being written: wait for more.
        XCTAssertEqual(ZstdTail.decodeCompleteFrames(frame("x") + Data("partial".utf8)).1, frame("x").count)
    }

    func testDecodesOnlyCompleteAppendedFrames() throws {
        let path = NSTemporaryDirectory() + "tessera-zstd-\(UUID().uuidString).zst"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try frame("{\"a\":1}\n").write(to: URL(fileURLWithPath: path))
        let tail = ZstdTail()
        XCTAssertEqual(tail.readAppended(path: path).map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}\n")
        XCTAssertNil(tail.readAppended(path: path))

        // A frame still being written: first half, then the rest.
        let second = frame("{\"b\":2}\n{\"c\":3}\n")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        handle.write(second.prefix(second.count / 2))
        XCTAssertNil(tail.readAppended(path: path))
        handle.write(second.suffix(from: second.count / 2))
        try handle.close()
        XCTAssertEqual(tail.readAppended(path: path).map { String(decoding: $0, as: UTF8.self) }, "{\"b\":2}\n{\"c\":3}\n")
    }

    func testReadsALongLogInPieces() throws {
        let path = NSTemporaryDirectory() + "tessera-zstd-\(UUID().uuidString).zst"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = (0..<20).map { "{\"n\":\($0)}\n" }
        try lines.map(frame).reduce(Data(), +).write(to: URL(fileURLWithPath: path))
        let tail = ZstdTail()
        var pieces: [String] = []
        // Smaller than one frame: each call still makes progress, a frame at a time.
        while let decoded = tail.readAppended(path: path, limit: 8) { pieces.append(String(decoding: decoded, as: UTF8.self)) }
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), lines.joined())
    }
}

final class DshTranscriptParserTests: XCTestCase {
    func testApprovalTurnAndMessages() {
        var p = DshTranscriptParser()
        let t0 = 1_789_422_265_000
        p.ingest(text: """
        {"type":"session","version":4,"id":"session-abc","createdAt":\(t0),"cwd":"/Users/me/proj","delegationDepth":0}
        {"type":"model/selection","seq":2,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}
        {"type":"turn/start","seq":5,"time":\(t0 + 100),"data":{"turn":1}}
        {"type":"user/message","seq":9,"time":\(t0 + 200),"data":{"content":[{"type":"text","text":"What is using RAM?"}],"source":{"kind":"user"}}}
        {"type":"user/message","seq":10,"time":\(t0 + 201),"data":{"content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"}],"source":{"kind":"system"}}}
        {"type":"assistant/message","seq":18,"time":\(t0 + 300),"data":{"message":{"content":[{"type":"reasoning","text":"thinking"},{"type":"text","text":"Checking processes."}]}}}
        {"type":"tool/call","seq":19,"time":\(t0 + 301),"data":{"callId":"c1","name":"bash","arguments":"{\\"command\\": \\"ps aux\\", \\"description\\": \\"List processes\\"}"}}
        {"type":"approval/asked","seq":20,"time":\(t0 + 302),"data":{"id":"a1","toolName":"bash","reason":"escalate sandbox"}}
        {"type":"session/title","seq":21,"data":{"title":"Mac RAM usage"}}
        """)
        let now = Date(timeIntervalSince1970: Double(t0) / 1000 + 5)
        var s = p.snapshot(now: now)
        XCTAssertEqual(p.title, "Mac RAM usage")
        XCTAssertEqual(p.sessionId, "session-abc")
        XCTAssertEqual(s.model, "deepseek-v4-flash")
        XCTAssertEqual(s.activity, .needsInput)
        XCTAssertEqual(s.detail, "Approve bash: escalate sandbox")
        XCTAssertEqual(s.items.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(s.items.last?.text, "List processes")

        p.ingest(text: """
        {"type":"approval/decided","seq":22,"time":\(t0 + 400),"data":{"id":"a1","outcome":"allowed-once"}}
        {"type":"tool/result","seq":23,"time":\(t0 + 500),"data":{"message":{"toolCallId":"c1","content":[{"type":"text","text":"ok"}],"isError":false}}}
        """)
        XCTAssertEqual(p.snapshot(now: now).activity, .working)
        p.ingest(text: #"{"type":"turn/end","seq":72,"time":\#(t0 + 600),"data":{"turn":1,"reason":{"kind":"completed"}}}"#)
        s = p.snapshot(now: now)
        XCTAssertEqual(s.activity, .done)
        XCTAssertEqual(s.items.last?.role, .toolResult)
    }

    func testDelegatedSessionsAreMarked() {
        var p = DshTranscriptParser()
        p.ingest(text: #"{"type":"session","id":"child","cwd":"/x","delegationDepth":1}"#)
        XCTAssertTrue(p.isDelegated)
    }
}

final class DshWebServerTests: XCTestCase {
    func testCapturesTheTokenURLAmongOtherOutput() {
        let out = """
        2026-09-28 19:27:37,433 - BlenderMCPServer - INFO - Response parsed, status: success
        dsh web: http://127.0.0.1:58070/?token=AbC_123-x
        """
        XCTAssertEqual(DshWebServer.launchURL(in: out)?.absoluteString, "http://127.0.0.1:58070/?token=AbC_123-x")
        XCTAssertNil(DshWebServer.launchURL(in: "dsh web: starting"))
        XCTAssertNil(DshWebServer.launchURL(in: "dsh web: http://127.0.0.1:1/"))
    }

    /// Startup files can print anything; only the probe's tagged lines count.
    func testLauncherFromTaggedProbeOutput() {
        let noisy = "Welcome back!\n/not/a/path\n@path /opt/bin:/usr/bin\n@npx /opt/bin/npx\n"
        XCTAssertEqual(DshWebServer.launcher(fromProbe: noisy).map { [$0.0] + $0.1 + [$0.2] },
                       ["/opt/bin/npx", "-y", "@deepseek-ai/dsh", "/opt/bin:/usr/bin"])
        XCTAssertEqual(DshWebServer.launcher(fromProbe: noisy + "@dsh /opt/bin/dsh\n")?.0, "/opt/bin/dsh")
        // An alias isn't something to run; nothing found means not installed.
        XCTAssertNil(DshWebServer.launcher(fromProbe: "@path /usr/bin\n@dsh alias dsh='x'\n"))
        XCTAssertNil(DshWebServer.launcher(fromProbe: "@dsh /opt/bin/dsh\n"))
    }

    /// A startup file that hangs can't hang the probe: interactive shells ignore SIGTERM, and what
    /// the shell started still holds its output open.
    func testLoginShellProbeGivesUpOnAHang() {
        XCTAssertEqual(LoginShell.run("echo '@probe ok'").map { LoginShell.tagged("probe", in: $0) }, ["ok"])
        let start = Date()
        XCTAssertNil(LoginShell.run("sleep 30", timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testSessionSelectionScriptQuotesTitles() {
        let js = Workspace.selectDshSessionScript(title: #"Fix "quotes" & </script>"#, folder: "enn'tity")
        XCTAssertTrue(js.contains(#"Fix \"quotes\""#))
        XCTAssertTrue(js.contains(#"["enn'tity"][0]"#))
        XCTAssertTrue(js.contains("more sessions") && js.contains("aria-expanded"))
    }
}
