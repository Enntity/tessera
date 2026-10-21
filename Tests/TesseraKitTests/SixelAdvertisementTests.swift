import AppKit
import SwiftTerm
import XCTest
@testable import TesseraHost

/// Harnesses like omp discover inline graphics the documented way (an XTSMGRAPHICS reply or
/// DA1 attribute 4) and then draw SIXEL images. SwiftTerm attaches a sixel to buffer lines,
/// and ordinary row-by-row repaints — how those agents redraw a viewport while streaming —
/// never clear attachments, so every repaint stacks another ghost of the image on screen.
/// Tessera cannot show those images in a thumbnail at all, so it must decline the
/// advertisement in its DA1 reply and let clients fall back to text charts.
@MainActor
final class SixelAdvertisementTests: XCTestCase {
    private final class ReplyCapture: NSObject, TerminalViewDelegate {
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

    private func da1Attributes(from view: TerminalView) -> [Int] {
        let capture = ReplyCapture()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[c") // DEC Private Mode: Send Device Attributes (Primary DA)
        let reply = String(decoding: capture.bytes, as: UTF8.self)
        XCTAssertTrue(reply.hasPrefix("\u{1b}[?"), "expected a DA1 reply, got \(reply)")
        return reply
            .replacingOccurrences(of: "\u{1b}[?", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "c"))
            .split(separator: ";")
            .compactMap { Int($0) }
    }

    func testTileTerminalDoesNotAdvertiseSixel() {
        let view = TesseraTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: nil)
        XCTAssertFalse(da1Attributes(from: view).contains(4),
                       "DA1 must not report sixel (attribute 4); inline images ghost on streaming repaints")
    }
}