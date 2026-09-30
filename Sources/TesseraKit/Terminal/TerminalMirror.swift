import Foundation
import Observation
import SwiftTerm

/// A display-only terminal fed from somewhere else (the host's PTY stream). It never answers the
/// program — the host's own terminal does that — it just keeps a screen to draw.
@Observable
public final class TerminalMirror: TerminalDelegate {
    @ObservationIgnored public private(set) var terminal: Terminal!
    /// Bumped on every change; the views showing this terminal (and only those) redraw.
    public private(set) var revision = 0

    public init(cols: Int = 120, rows: Int = 36) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 2000))
    }

    public func reset(cols: Int, rows: Int, bytes: [UInt8]) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 2000))
        terminal.feed(byteArray: bytes)
        revision &+= 1
    }

    public func feed(_ bytes: [UInt8], cols: Int? = nil, rows: Int? = nil) {
        if let cols, let rows, cols != terminal.cols || rows != terminal.rows {
            terminal.resize(cols: cols, rows: rows)
        }
        terminal.feed(byteArray: bytes)
        revision &+= 1
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
