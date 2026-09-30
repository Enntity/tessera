import SwiftUI
import XCTest
@testable import TesseraKit

/// The rules the palette keeps: text reads on every surface, and a saturated color means a state.
final class StyleTests: XCTestCase {
    private func luminance(_ color: Color) -> Double {
        let c = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
    }

    /// WCAG contrast ratio.
    private func contrast(_ text: Color, on surface: Color) -> Double {
        let (a, b) = (luminance(text), luminance(surface))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testTextReadsOnEverySurface() {
        for surface in [Style.void, Style.deck, Style.glass, Style.terminalBackground] {
            XCTAssertGreaterThanOrEqual(contrast(Style.muted, on: surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(Style.dim, on: surface), 5.5)
            XCTAssertGreaterThanOrEqual(contrast(Style.ink, on: surface), 12)
            // The four states are text too: pills, counters, a failure's footer.
            for state in [Style.cyan, Style.amber, Style.mint, Style.coral] {
                XCTAssertGreaterThanOrEqual(contrast(state, on: surface), 4.5)
            }
        }
        // A primary button is ink with the void for its label.
        XCTAssertGreaterThanOrEqual(contrast(Style.void, on: Style.ink), 12)
    }

    func testOnlyStatesWearStateColors() {
        let states = [TileActivity.working, .needsInput, .done, .failed].map { Style.state($0) }
        XCTAssertEqual(Set(states.map { $0.description }).count, 4)
        for flavor in AgentFlavor.allCases {
            XCTAssertFalse(states.contains(Style.accent(flavor)), "\(flavor) wears a state's color")
        }
        XCTAssertFalse(states.contains(Style.control))
        // What isn't one of the four states is quiet.
        for quiet in [TileActivity.starting, .idle, .exited] {
            XCTAssertEqual(Style.state(quiet), Style.muted)
        }
    }
}
