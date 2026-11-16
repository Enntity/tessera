import XCTest
@testable import TesseraKit

final class ConversationBlocksTests: XCTestCase {
    private func split(_ text: String) -> [ConversationBlock] { ConversationBlocks.split(text) }

    /// Ordinary lines join into a paragraph per blank-line run.
    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(split("One line.\nStill one.\n\nNext."),
                       [.paragraph("One line.\nStill one."), .paragraph("Next.")])
    }

    /// `- ` and `* ` lines become bullet rows, `1. ` numbered rows, `#`–`###` headings.
    func testBulletsNumbersAndHeadings() {
        XCTAssertEqual(split("Two things:\n\n- **kestrel** failed\n* harbor waits\n\n1. first\n2. second\n\n## Stuck"),
                       [.paragraph("Two things:"),
                        .bullet("**kestrel** failed"), .bullet("harbor waits"),
                        .number(1, "first"), .number(2, "second"),
                        .heading(2, "Stuck")])
    }

    /// A fenced run is code, verbatim — nothing in it is parsed.
    func testFencesAreVerbatimCode() {
        XCTAssertEqual(split("Run this:\n\n```sh\n- not a bullet\n# not a heading\n```\n\nDone."),
                       [.paragraph("Run this:"), .code("- not a bullet\n# not a heading"), .paragraph("Done.")])
    }

    /// An unclosed fence still ends up code; a paragraph keeps only its own lines.
    func testEdgeCases() {
        XCTAssertEqual(split("```\nlet x = 1"), [.code("let x = 1")])
        XCTAssertEqual(split("plain"), [.paragraph("plain")])
        XCTAssertEqual(split("3.a kept"), [.paragraph("3.a kept")])
    }
}
