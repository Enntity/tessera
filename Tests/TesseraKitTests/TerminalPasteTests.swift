import AppKit
import SwiftTerm
import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// A context that captures everything a paste routes, reads from a named pasteboard of the test's
/// own (so no test ever touches the user's real clipboard), and can hand a native paste off to a
/// supplied closure exactly as the real view's keyDown encoder would.
@MainActor
private final class PasteRecorder: TerminalPasteContext, TerminalNativePaste {
    let pasteboard: NSPasteboard
    var sent: [[UInt8]] = []
    private(set) var beeps = 0
    private(set) var notices: [String] = []
    var bracketed = false
    var flavor: AgentFlavor = .shell
    var fallbackURL: URL?
    /// Records a native clipboard-paste hand-off; returns whether one happened.
    var nativePaste: (() -> Bool)?

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var sentString: String { String(decoding: sent.flatMap { $0 }, as: UTF8.self) }

    func pasteSend(_ bytes: [UInt8]) { sent.append(bytes) }
    func pasteBracketedPasteMode() -> Bool { bracketed }
    func pasteBeep() { beeps += 1 }
    func pasteImageFallbackURL() -> URL? { fallbackURL }
    func pasteFlavor() -> AgentFlavor { flavor }
    func pasteNotice(_ message: String) { notices.append(message) }
    func sendNativePaste() -> Bool { nativePaste?() ?? false }
}

@MainActor
final class TerminalPasteTests: XCTestCase {
    private func namedPasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("tessera-test-\(UUID().uuidString)"))
        board.clearContents()
        addTeardownBlock { board.clearContents() }
        return board
    }

    private func write(_ board: NSPasteboard, _ value: String, type: NSPasteboard.PasteboardType) {
        board.clearContents()
        board.setString(value, forType: type)
    }

    private func imageData() -> Data {
        let image = NSImage(size: CGSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Plain text

    /// Plain text is framed by bracketed paste explicitly (framing belongs to the routed bytes, so
    /// it survives even when it is not SwiftTerm's internal paste path), with no notice.
    func testPlainTextPasteIsBracketedWhenModeOn() {
        let board = namedPasteboard()
        write(board, "line one\nline two", type: .string)
        let context = PasteRecorder(pasteboard: board)
        context.bracketed = true

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sentString, "\u{1b}[200~line one\nline two\u{1b}[201~")
        XCTAssertTrue(context.notices.isEmpty)
    }

    /// Without bracketed mode the text goes in literally, unframed.
    func testPlainTextPasteUnframedWhenModeOff() {
        let board = namedPasteboard()
        write(board, "echo hi", type: .string)
        let context = PasteRecorder(pasteboard: board)

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sentString, "echo hi")
        XCTAssertTrue(context.notices.isEmpty)
    }

    /// A `.URL` representation is pasted as text.
    func testURLOnlyPasteUsesTheURLRepresentation() {
        let board = namedPasteboard()
        write(board, "https://example.com/x?y=1", type: .URL)
        let context = PasteRecorder(pasteboard: board)

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sentString, "https://example.com/x?y=1")
    }

    /// A URL-only clipboard with no bracketed mode is not framed.
    func testURLOnlyPasteIsNotFramedWithoutBracketMode() {
        let board = namedPasteboard()
        write(board, "https://example.com/x", type: .URL)
        let context = PasteRecorder(pasteboard: board)
        context.bracketed = true
        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)
        XCTAssertEqual(context.sentString, "\u{1b}[200~https://example.com/x\u{1b}[201~")
    }

    /// An RTF-only clipboard contributes its plain text projection.
    func testRTFPasteUsesPlainTextProjection() {
        let board = namedPasteboard()
        board.clearContents()
        let attributed = NSAttributedString(string: "rich text", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let rtf = try! attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        let context = PasteRecorder(pasteboard: board)

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sentString, "rich text")
    }

    /// An empty clipboard is a visible failure, not a silent no-op.
    func testEmptyClipboardBeepsAndSaysNothingToPaste() {
        let board = namedPasteboard()
        board.clearContents()
        let context = PasteRecorder(pasteboard: board)

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.beeps, 1)
        XCTAssertEqual(context.notices, ["Nothing to paste"])
        XCTAssertTrue(context.sent.isEmpty)
    }

    // MARK: Files

    /// File URLs beat the Finder preview/text they may be accompanied by, are quoted, and are framed
    /// as one bracketed paste with no trailing newline and no submit.
    func testFileURLsAreQuotedAndDoNotSubmit() {
        let board = namedPasteboard()
        let a = URL(fileURLWithPath: "/tmp/tessera space/o'brien.txt")
        let b = URL(fileURLWithPath: "/tmp/plain/second.png")
        board.clearContents()
        board.writeObjects([a as NSURL, b as NSURL])
        // Finder also puts a preview text on the same copy; the real paths must win.
        board.setString("space\nobrien\nsecond", forType: .string)
        let context = PasteRecorder(pasteboard: board)
        context.bracketed = true

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        let quoted = "'/tmp/tessera space/o'\\''brien.txt' '/tmp/plain/second.png'"
        XCTAssertEqual(context.sentString, "\u{1b}[200~\(quoted)\u{1b}[201~")
        XCTAssertEqual(context.sent.count, 1, "one write, so no framing or newline between files")
        XCTAssertFalse(context.sentString.contains("\n"))
        XCTAssertFalse(context.sentString.contains("\r"))
    }

    func testQuoteHandlesSpacesQuotesAndEmptyPath() {
        XCTAssertEqual(TerminalPaste.quote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(TerminalPaste.quote("/a'b"), "'/a'\\''b'")
        XCTAssertEqual(TerminalPaste.quote(""), "''")
    }

    /// A file name with a control byte (newline) is rejected instead of typed as executable input.
    func testFilePathWithControlByteIsRejected() {
        let board = namedPasteboard()
        board.clearContents()
        board.setString("file:///tmp/evil%0Atouch%20pwned", forType: .fileURL)
        // The URL encoding above round-trips to a path containing a newline.
        let context = PasteRecorder(pasteboard: board)
        context.bracketed = false

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertTrue(context.sentString.isEmpty, "a newline in a path must never reach the PTY")
        XCTAssertEqual(context.beeps, 1)
    }

    // MARK: Images

    /// A screenshot / browser image copy holds an image and often a `.URL` or text too; the image
    /// must win over that companion representation.
    func testImageBeatsCompanionURLAndString() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        board.setString("https://example.com/picture", forType: .URL)
        board.setString("https://example.com/picture", forType: .string)
        XCTAssertEqual(TerminalPaste.classify(board), .image)
    }

    /// An image on a non-shell command routes a native clipboard paste through the encoder, never raw
    /// bytes and never the image itself.
    func testImageOnNonShellRoutesNativePaste() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        let context = PasteRecorder(pasteboard: board)
        context.flavor = .claude
        context.nativePaste = { context.sent.append([0x16]); return true }

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sent, [[0x16]])
    }

    /// Any non-shell flavor takes the native path: no per-tool allowlist.
    func testNativeImageRoutingIsNotLimitedToClaudeOrCodex() {
        for flavor in [AgentFlavor.claude, .codex, .grok, .opencode, .custom, .dsh, .gemini, .omp, .aider, .web, .claudeDesktop, .codexDesktop] {
            let board = namedPasteboard()
            board.clearContents()
            board.setData(imageData(), forType: .png)
            let context = PasteRecorder(pasteboard: board)
            context.flavor = flavor
            context.bracketed = true
            context.nativePaste = { context.sent.append([0x16]); return true }
            TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)
            XCTAssertEqual(context.sent, [[0x16]], "\(flavor) should route the native clipboard paste")
        }
    }

    /// A plain shell has no native image input: it saves a private local PNG and pastes its quoted
    /// path as framed text.
    func testShellImageSavesPNGAndTypesTheQuotedPath() throws {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-paste-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let context = PasteRecorder(pasteboard: board)
        context.flavor = .shell
        context.bracketed = true
        let url = dir.appendingPathComponent("shot.png")
        context.fallbackURL = url

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sentString, "\u{1b}[200~'\(url.path)'\u{1b}[201~")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// When no local path can be used (a remote tile), the image fails visibly instead of typing a
    /// local file the remote program cannot reach.
    func testImageWithNoFallbackBeeps() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        let context = PasteRecorder(pasteboard: board)
        context.flavor = .shell
        context.fallbackURL = nil

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.beeps, 1)
        XCTAssertTrue(context.sent.isEmpty)
        XCTAssertFalse(context.notices.isEmpty)
    }

    /// The shell fallback writes into a unique private directory, so an image is never overwritten.
    func testImageFallbackURLsAreUniqueAndPrivate() {
        let dir = TerminalPaste.imageFallbackDirectory()
        XCTAssertTrue(dir.path.contains("Tessera/PastedImages"), dir.path)
        let one = TerminalPaste.imageFallbackURL()
        let two = TerminalPaste.imageFallbackURL(now: Date(timeIntervalSince1970: 0))
        XCTAssertNotEqual(one.path, two.path)
        XCTAssertTrue(one.path.hasSuffix(".png"))
    }

    /// The saved image is private: directory 0700, file 0600, and an existing path is never replaced.
    func testSavedImageHasSecureFileModesAndDoesNotReplace() throws {
        let board = namedPasteboard()
        board.clearContents()
        let png = imageData()
        board.setData(png, forType: .png)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-mode-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")

        XCTAssertTrue(TerminalPaste.savePNG(from: board, to: url))

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // A valid PNG is preserved byte for byte.
        XCTAssertEqual(try Data(contentsOf: url), png)
        // Trying to save over the same path must fail rather than replace.
        XCTAssertFalse(TerminalPaste.savePNG(from: board, to: url))
    }

    // MARK: Unknown binary

    /// Unknown binary data is never emitted raw into the PTY.
    func testUnknownBinaryIsNeverSentRawAndBeeps() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(Data([0x00, 0xff, 0x10, 0x80]), forType: NSPasteboard.PasteboardType("com.tessera.unknown-binary"))
        let context = PasteRecorder(pasteboard: board)

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertTrue(context.sentString.isEmpty)
        XCTAssertEqual(context.beeps, 1)
    }

    func testUnknownClipboardFormatReachesCustomHarness() {
        let board = namedPasteboard()
        board.setData(Data([0x00, 0xff, 0x10]), forType: NSPasteboard.PasteboardType("com.harness.attachment"))
        let context = PasteRecorder(pasteboard: board)
        context.flavor = .custom
        context.nativePaste = { context.sent.append([0x16]); return true }

        TerminalPaste.performPaste(on: TesseraTerminalView(frame: .zero, font: nil), context: context)

        XCTAssertEqual(context.sent, [[0x16]])
        XCTAssertEqual(context.beeps, 0)
    }

    // MARK: Drop

    /// A dropped image reads the drag pasteboard (not the general clipboard) and materializes a
    /// local path; a shell never sees Ctrl+V.
    func testDroppedImageUsesDragPasteboardNotClipboard() throws {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-drop-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clipboard = namedPasteboard()
        clipboard.setString("different clipboard content", forType: .string)
        let context = PasteRecorder(pasteboard: clipboard)
        context.flavor = .custom
        context.nativePaste = { context.sent.append([0x16]); return true }
        context.bracketed = true
        let url = dir.appendingPathComponent("dropped.png")
        context.fallbackURL = url

        let ok = TerminalPaste.performDrop(from: board, context: context)

        XCTAssertTrue(ok)
        XCTAssertEqual(context.sentString, "\u{1b}[200~'\(url.path)'\u{1b}[201~")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), board.data(forType: .png))
        XCTAssertTrue(context.sent.allSatisfy { !$0.contains(0x16) } || context.sent.isEmpty)
    }

    /// A drop that cannot be materialized or typed returns false and beeps, with no misleading
    /// success, so the drag system does not report a completed drop.
    func testUndeliverableDropReturnsFalseAndBeeps() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(Data([0x00, 0x01]), forType: NSPasteboard.PasteboardType("com.tessera.mystery"))
        let context = PasteRecorder(pasteboard: board)

        let ok = TerminalPaste.performDrop(from: board, context: context)

        XCTAssertFalse(ok)
        XCTAssertEqual(context.beeps, 1)
        XCTAssertTrue(context.sent.isEmpty)
    }

    /// A remote shell image drop that has no local path returns false and beeps.
    func testRemoteImageDropWithoutLocalPathReturnsFalse() {
        let board = namedPasteboard()
        board.clearContents()
        board.setData(imageData(), forType: .png)
        let context = PasteRecorder(pasteboard: board)
        context.flavor = .shell
        context.fallbackURL = nil

        XCTAssertFalse(TerminalPaste.performDrop(from: board, context: context))
        XCTAssertEqual(context.beeps, 1)
    }

    // MARK: View routing

    /// Pressing/swallowing ⌘V with Caps Lock on must still count as the standard paste shortcut.
    func testCommandVWithCapsLockIsStandardShortcut() throws {
        let view = TesseraTerminalView(frame: .zero, font: nil)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: [.command, .capsLock],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "v", charactersIgnoringModifiers: "v",
                                                    isARepeat: false, keyCode: 9))
        XCTAssertTrue(view.isStandardPasteShortcut(event))
    }

    /// Only plain Command-V is our paste shortcut.
    func testNonStandardShortcutsAreNotSwallowed() throws {
        let view = TesseraTerminalView(frame: .zero, font: nil)
        for flags: NSEvent.ModifierFlags in [.control, .option, .command.union(.shift), .command.union(.option), []] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                        timestamp: 0, windowNumber: 0, context: nil,
                                                        characters: "v", charactersIgnoringModifiers: "v",
                                                        isARepeat: false, keyCode: 9))
            XCTAssertFalse(view.isStandardPasteShortcut(event), "\(flags) must reach keyDown, not paste")
        }
    }

    /// The view's performKeyEquivalent routes a ⌘V event through the injected context.
    func testViewRoutesCommandVThroughContext() throws {
        let board = namedPasteboard()
        write(board, "routed", type: .string)
        let context = PasteRecorder(pasteboard: board)
        let view = TesseraTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), font: nil)
        view.pasteContext = context

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "v",
                                                    charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(context.sentString, "routed")
    }

    /// The view's standard paste action (Edit▸Paste / ⌘V) also routes through the context.
    func testViewPasteActionRoutesThroughContext() {
        let board = namedPasteboard()
        write(board, "from menu", type: .string)
        let context = PasteRecorder(pasteboard: board)
        let view = TesseraTerminalView(frame: .zero, font: nil)
        view.pasteContext = context

        view.paste(nil)

        XCTAssertEqual(context.sentString, "from menu")
    }

    func testOtherWindowReleaseDoesNotConsumePasteShortcutRelease() throws {
        _ = NSApplication.shared
        let board = namedPasteboard()
        board.setString("paste", forType: .string)
        let context = PasteRecorder(pasteboard: board)
        let view = TesseraTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), font: nil)
        view.pasteContext = context
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        func event(_ type: NSEvent.EventType, in target: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                          context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                          isARepeat: false, keyCode: 9))
        }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(.keyDown, in: window)))
        XCTAssertNotNil(view.filterPasteRelease(try event(.keyUp, in: other)))
        XCTAssertNil(view.filterPasteRelease(try event(.keyUp, in: window)))
        XCTAssertNotNil(view.filterPasteRelease(try event(.keyUp, in: window)))
    }

    // MARK: TerminalSession wiring

    /// The actual session owns a TesseraTerminalView, not a raw SwiftTerm one.
    func testSessionOwnsThePasteAwareView() {
        let session = TerminalSession(command: "sleep 30", cwd: NSTemporaryDirectory(), startSuspended: true)
        XCTAssertTrue(session.view is TesseraTerminalView)
        XCTAssertNotNil(session.view.pasteContext)
    }
}

/// Tests driven against the real view + real session, on captured delegate bytes rather than a stub.
@MainActor
final class TerminalPasteRealViewTests: XCTestCase {
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

    private func imageData() -> Data {
        let image = NSImage(size: CGSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    /// Real multiline text must keep its bracket framing on the delegate's byte stream.
    func testRealViewKeepsMultilineTextInOneBracketedPaste() {
        let (session, capture) = sessionWithCapture()
        let text = "first line\nsecond line\t✓"
        TerminalPaste.sendText(text, context: session)
        XCTAssertEqual(capture.bytes, Array("\u{1b}[200~\(text)\u{1b}[201~".utf8))
    }

    /// A real file paste carries only quoted paths inside the framing — no notice, no CRLF, no submit.
    func testRealFilePasteContainsOnlyQuotedPathsAndPasteFraming() {
        let (session, capture) = sessionWithCapture()
        let files = [URL(fileURLWithPath: "/tmp/one two.png"),
                     URL(fileURLWithPath: "/tmp/o'brien;$(touch nope).pdf")]
        TerminalPaste.sendPaths(files, context: session)
        let expected = "\u{1b}[200~'/tmp/one two.png' '/tmp/o'\\''brien;$(touch nope).pdf'\u{1b}[201~"
        XCTAssertEqual(capture.bytes, Array(expected.utf8), "No notices or submit keys may reach the program")
    }

    /// A native Ctrl+V synthesized by the view must equal a real Ctrl+V through keyDown, in legacy mode.
    func testNativeControlVMatchesDirectKeyDownLegacy() throws {
        let (session, capture) = sessionWithCapture()
        let direct = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "\u{16}",
                                                    charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        session.view.keyDown(with: direct)
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .control,
                                                     timestamp: 0, windowNumber: 0, context: nil, characters: "\u{16}",
                                                     charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        session.view.keyUp(with: release)
        let directBytes = capture.bytes
        capture.bytes = []
        XCTAssertTrue(session.view.sendNativeControlV())
        XCTAssertEqual(capture.bytes, directBytes)
        XCTAssertFalse(directBytes.isEmpty)
    }

    /// Same equivalence once the program has negotiated Kitty keyboard flags.
    func testNativeControlVMatchesDirectKeyDownKitty() throws {
        let (session, capture) = sessionWithCapture()
        // Push Kitty disambiguation and event reporting, then reset capture.
        session.view.feed(byteArray: Array("\u{1b}[>3u".utf8)[...])
        XCTAssertFalse(session.view.getTerminal().keyboardEnhancementFlags.isEmpty)
        capture.bytes = []
        let direct = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "\u{16}",
                                                    charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        session.view.keyDown(with: direct)
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .control,
                                                     timestamp: 0, windowNumber: 0, context: nil, characters: "\u{16}",
                                                     charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        session.view.keyUp(with: release)
        let directBytes = capture.bytes
        capture.bytes = []
        XCTAssertTrue(session.view.sendNativeControlV())
        XCTAssertEqual(capture.bytes, directBytes)
    }

    /// A real dropped image on a plain shell becomes a quoted local path in the framing, and the
    /// delegate never sees a Ctrl+V byte.
    func testRealDropOfImageOnShellPastesQuotedPath() throws {
        let (session, capture) = sessionWithCapture()
        let board = NSPasteboard(name: NSPasteboard.Name("tessera-realview-\(UUID().uuidString)"))
        board.clearContents()
        addTeardownBlock { board.clearContents() }
        board.setData(imageData(), forType: .png)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-real-fallback-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dropped.png")
        session.pasteImageFallbackOverride = url
        defer { session.pasteImageFallbackOverride = nil }

        XCTAssertTrue(TerminalPaste.performDrop(from: board, context: session))
        XCTAssertEqual(capture.bytes, Array("\u{1b}[200~'\(url.path)'\u{1b}[201~".utf8))
        XCTAssertFalse(capture.bytes.contains(0x16))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
