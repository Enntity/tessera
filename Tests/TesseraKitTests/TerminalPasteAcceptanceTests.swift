import AppKit
import SwiftTerm
import XCTest
@testable import TesseraHost

/// Check the real session/view output, rather than a paste-context stub.
@MainActor
final class TerminalPasteAcceptanceTests: XCTestCase {
    private final class InputCapture: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func sessionWithCapture() -> (TerminalSession, InputCapture) {
        let session = TerminalSession(command: nil, cwd: NSTemporaryDirectory(), startSuspended: true)
        let capture = InputCapture()
        session.view.terminalDelegate = capture
        session.view.feed(byteArray: Array("\u{1b}[?2004h".utf8)[...])
        XCTAssertTrue(session.terminal.bracketedPasteMode)
        capture.bytes = []
        return (session, capture)
    }

    func testRealViewKeepsMultilineTextInOneBracketedPaste() {
        let (session, capture) = sessionWithCapture()
        let text = "first line\nsecond line\t✓"
        session.pasteInsertText(text, isPaste: true)
        XCTAssertEqual(capture.bytes, Array("\u{1b}[200~\(text)\u{1b}[201~".utf8))
    }

    func testTextPasteClearsPendingInputMethodComposition() {
        let (session, capture) = sessionWithCapture()
        session.view.setMarkedText("pending", selectedRange: NSRange(location: 0, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.view.hasMarkedText())
        session.pasteInsertText("pasted", isPaste: true)
        XCTAssertFalse(session.view.hasMarkedText())
        XCTAssertEqual(capture.bytes, Array("\u{1b}[200~pasted\u{1b}[201~".utf8))
    }

    func testRealFilePasteContainsOnlyQuotedPathsAndPasteFraming() {
        let (session, capture) = sessionWithCapture()
        let files = [URL(fileURLWithPath: "/tmp/one two.png"),
                     URL(fileURLWithPath: "/tmp/o'brien;$(touch nope).pdf")]
        TerminalPaste.sendPaths(files, context: session)
        let expected = "\u{1b}[200~'/tmp/one two.png' '/tmp/o'\\''brien;$(touch nope).pdf'\u{1b}[201~"
        XCTAssertEqual(capture.bytes, Array(expected.utf8), "No notices or submit keys may reach the program")
    }

    func testPasteBytesReachRealPTYWithoutExtraInput() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-paste-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = dir.appendingPathComponent("probe.py")
        let received = dir.appendingPathComponent("received.bin")
        let text = "first\nsecond\t✓"
        let file = URL(fileURLWithPath: "/tmp/one two.png")
        let expected = Array("\u{1b}[200~'/tmp/one two.png'\u{1b}[201~\u{1b}[200~\(text)\u{1b}[201~\u{1b}[118;5u\u{1b}[118;5:3u".utf8)
        let script = """
        import os, sys, tty
        tty.setraw(0)
        os.write(1, b'\u{5c}x1b[?2004h\u{5c}x1b[>3uPASTE_CANARY_READY\u{5c}r\u{5c}n')
        data = b''
        while len(data) < int(sys.argv[2]):
            data += os.read(0, 4096)
        with open(sys.argv[1], 'wb') as output:
            output.write(data)
        """
        try script.write(to: probe, atomically: true, encoding: .utf8)
        let session = TerminalSession(command: "/usr/bin/python3 '\(probe.path)' '\(received.path)' \(expected.count)",
                                      cwd: dir.path, shell: "/bin/bash",
                                      environmentOverrides: ["HOME": dir.path, "HISTFILE": dir.appendingPathComponent("history").path])
        defer { session.terminate() }
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        XCTAssertTrue(waitUntil { session.terminal.bracketedPasteMode && !session.terminal.keyboardEnhancementFlags.isEmpty })
        TerminalPaste.sendPaths([file], context: session)
        session.pasteInsertText(text, isPaste: true)
        XCTAssertTrue(session.sendNativePaste())
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: received.path) })
        XCTAssertEqual(try Data(contentsOf: received), Data(expected))
    }
}
