import CoreGraphics
import CoreText
import Foundation
import SwiftTerm

public struct RGB: Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    func cgColor(alpha: CGFloat) -> CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha) }
}

/// Terminal colors shared by the macOS full view, thumbnails and the iOS client, so a tile looks the
/// same at every size and on every device.
public struct TerminalTheme: Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    public var ansi: [RGB]

    public static let midnight = TerminalTheme(
        foreground: RGB(0xD8, 0xDE, 0xE9), background: RGB(0x0A, 0x0D, 0x14), cursor: RGB(0x7C, 0xF3, 0xD4),
        ansi: [
            RGB(0x1B, 0x20, 0x2A), RGB(0xFF, 0x5F, 0x6D), RGB(0x5B, 0xE4, 0x9B), RGB(0xFF, 0xC8, 0x57),
            RGB(0x5C, 0x9D, 0xFF), RGB(0xC3, 0x7D, 0xFF), RGB(0x4F, 0xD6, 0xE8), RGB(0xC8, 0xCE, 0xDA),
            RGB(0x4A, 0x52, 0x63), RGB(0xFF, 0x86, 0x91), RGB(0x86, 0xF0, 0xB6), RGB(0xFF, 0xDA, 0x85),
            RGB(0x8C, 0xBB, 0xFF), RGB(0xD7, 0xA6, 0xFF), RGB(0x86, 0xE6, 0xF2), RGB(0xF4, 0xF6, 0xFA)
        ])

    /// Full xterm-256 palette with this theme's 16 base colors.
    public var palette256: [RGB] {
        var p = ansi
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { p.append(RGB(r, g, b)) } } }
        for i in 0..<24 { let v = UInt8(8 + i * 10); p.append(RGB(v, v, v)) }
        return p
    }
}

/// Draws a SwiftTerm screen into any CGContext. At thumbnail scale glyphs become a colored
/// "minimap" of blocks, which reads as live activity and costs almost nothing; once cells are
/// big enough to read, real text is drawn.
public final class MiniTerminalRenderer {
    public let theme: TerminalTheme
    private let palette: [RGB]
    private var fontCache: [Int: CTFont] = [:]
    private var colorCache: [RGB: CGColor] = [:]

    /// Below this cell height (points) text is unreadable, so draw blocks.
    public var textThreshold: CGFloat = 5.5

    public init(theme: TerminalTheme = .midnight) {
        self.theme = theme
        self.palette = theme.palette256
    }

    /// Cell size that fits the whole screen into `size` while keeping a terminal-like cell shape.
    public static func cellSize(cols: Int, rows: Int, fitting size: CGSize) -> CGSize {
        guard cols > 0, rows > 0 else { return .zero }
        let w = size.width / CGFloat(cols)
        let h = min(size.height / CGFloat(rows), w * 2.2)
        return CGSize(width: min(w, h / 1.6), height: h)
    }

    /// `ctx` must be in a top-left-origin, y-down coordinate space (SwiftUI Canvas, flipped NSView, UIView).
    /// `obscured` (privacy mode) draws a block per word in place of the text, at the same size and place.
    /// Cell height used when the whole screen won't fit readably: text at roughly 6 pt.
    public var focusCellHeight: CGFloat = 8

    /// Draws the terminal into `size`. If the whole screen fits at a readable size it is drawn as
    /// text; if not, the tile shows a readable crop anchored at the live edge (where agents print
    /// their latest output).
    public func draw(_ terminal: Terminal, in ctx: CGContext, size: CGSize, showCursor: Bool = true, obscured: Bool = false) {
        ctx.setFillColor(color(theme.background))
        ctx.fill(CGRect(origin: .zero, size: size))
        let cols = terminal.cols, rows = terminal.rows
        let fit = Self.cellSize(cols: cols, rows: rows, fitting: size)
        guard fit.width > 0.2 else { return }

        if fit.height >= textThreshold {
            // Whole screen, bottom-anchored.
            let yOffset = max(0, size.height - fit.height * CGFloat(rows))
            let font = obscured ? nil : self.font(size: fit.height * 0.78)
            drawRows(terminal, rows: 0..<rows, cols: cols, cell: fit, origin: CGPoint(x: 0, y: yOffset), font: font, in: ctx)
            if showCursor { drawCursor(terminal, firstRow: 0, rows: rows, cell: fit, origin: CGPoint(x: 0, y: yOffset), in: ctx) }
            return
        }

        // Readable crop: as many rows and columns as fit at the focus size, ending at the live edge.
        // Menlo advances ~0.6 em and the font is 0.78 of the cell height.
        let cell = CGSize(width: focusCellHeight * 0.78 * 0.6, height: focusCellHeight)
        let visibleRows = max(1, Int(size.height / cell.height))
        let visibleCols = max(1, Int(ceil(size.width / cell.width)))
        let edge = max(lastTextRow(terminal), terminal.getCursorLocation().y)
        let first = max(0, min(edge - visibleRows + 1, rows - visibleRows))
        let range = first..<min(rows, first + visibleRows)
        drawRows(terminal, rows: range, cols: min(cols, visibleCols), cell: cell, origin: .zero,
                 font: obscured ? nil : self.font(size: cell.height * 0.78), in: ctx)
        if showCursor { drawCursor(terminal, firstRow: first, rows: range.upperBound, cell: cell, origin: .zero, in: ctx) }
    }

    private func drawRows(_ terminal: Terminal, rows: Range<Int>, cols: Int, cell: CGSize, origin: CGPoint,
                          font: CTFont?, in ctx: CGContext) {
        for row in rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let y = origin.y + CGFloat(row - rows.lowerBound) * cell.height
            var col = 0
            let count = min(cols, line.count)
            while col < count {
                let start = col
                let attr = line[col].attribute
                var text = ""
                while col < count, line[col].attribute == attr {
                    let ch = line[col]
                    if ch.width != 0 {
                        let c = ch.getCharacter()
                        text.append(c == "\u{0}" ? " " : c)
                    }
                    col += 1
                }
                let (fg, bg, alpha) = resolve(attr)
                let runRect = CGRect(x: origin.x + CGFloat(start) * cell.width, y: y, width: CGFloat(col - start) * cell.width, height: cell.height)
                if bg != theme.background {
                    ctx.setFillColor(color(bg))
                    ctx.fill(runRect)
                }
                if attr.style.contains(.invisible) { continue }
                if let font {
                    drawText(text, font: font, color: fg.cgColor(alpha: alpha), at: CGPoint(x: runRect.minX, y: y + cell.height * 0.8), in: ctx)
                } else {
                    drawBlocks(text, fg: fg, alpha: alpha, origin: runRect.origin, cell: cell, in: ctx)
                }
            }
        }
    }

    private func drawCursor(_ terminal: Terminal, firstRow: Int, rows: Int, cell: CGSize, origin: CGPoint, in ctx: CGContext) {
        let loc = terminal.getCursorLocation()
        guard loc.y >= firstRow, loc.y < rows else { return }
        ctx.setFillColor(theme.cursor.cgColor(alpha: 0.85))
        ctx.fill(CGRect(x: origin.x + CGFloat(loc.x) * cell.width, y: origin.y + CGFloat(loc.y - firstRow) * cell.height,
                        width: max(cell.width, 1), height: cell.height))
    }

    /// The lowest visible row with any text on it.
    private func lastTextRow(_ terminal: Terminal) -> Int {
        var row = terminal.rows - 1
        while row > 0 {
            if let line = terminal.getLine(row: row) {
                let n = min(line.count, terminal.cols)
                if (0..<n).contains(where: { let c = line[$0].getCharacter(); return c != " " && c != "\u{0}" }) { return row }
            }
            row -= 1
        }
        return 0
    }

    private func drawBlocks(_ text: String, fg: RGB, alpha: CGFloat, origin: CGPoint, cell: CGSize, in ctx: CGContext) {
        ctx.setFillColor(fg.cgColor(alpha: alpha * 0.75))
        var x = origin.x
        let h = max(cell.height * 0.7, 0.6)
        let inset = (cell.height - h) / 2
        var runStart: CGFloat?
        for ch in text {
            let blank = ch == " "
            if !blank, runStart == nil { runStart = x }
            if blank, let s = runStart {
                ctx.fill(CGRect(x: s, y: origin.y + inset, width: x - s, height: h))
                runStart = nil
            }
            x += cell.width
        }
        if let s = runStart { ctx.fill(CGRect(x: s, y: origin.y + inset, width: x - s, height: h)) }
    }

    private func drawText(_ text: String, font: CTFont, color: CGColor, at baseline: CGPoint, in ctx: CGContext) {
        guard text.contains(where: { $0 != " " }) else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = baseline
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func resolve(_ attr: Attribute) -> (fg: RGB, bg: RGB, alpha: CGFloat) {
        var fg = rgb(attr.fg, isForeground: true, bold: attr.style.contains(.bold))
        var bg = rgb(attr.bg, isForeground: false, bold: false)
        if attr.style.contains(.inverse) { swap(&fg, &bg) }
        return (fg, bg, attr.style.contains(.dim) ? 0.55 : 1)
    }

    private func rgb(_ c: Attribute.Color, isForeground: Bool, bold: Bool) -> RGB {
        switch c {
        case .ansi256(let code):
            let idx = Int(code)
            return palette[bold && idx < 8 ? idx + 8 : min(idx, palette.count - 1)]
        case .trueColor(let r, let g, let b): return RGB(r, g, b)
        case .defaultColor: return isForeground ? theme.foreground : theme.background
        case .defaultInvertedColor: return isForeground ? theme.background : theme.background
        }
    }

    private func color(_ c: RGB) -> CGColor {
        if let hit = colorCache[c] { return hit }
        let made = c.cgColor
        colorCache[c] = made
        return made
    }

    private func font(size: CGFloat) -> CTFont {
        let key = Int(size * 4)
        if let f = fontCache[key] { return f }
        let f = CTFontCreateWithName("Menlo" as CFString, CGFloat(key) / 4, nil)
        fontCache[key] = f
        return f
    }
}

public extension Terminal {
    /// The `count` visible rows ending at the live edge — the cursor or the last row with text,
    /// whichever is lower — trailing spaces trimmed. Feeds prompt detection. (A fresh terminal's
    /// content sits at the top, so "the bottom rows" would be blank.)
    func screenTail(_ count: Int) -> [String] {
        let all: [String] = (0..<rows).map { row in
            var text = getLine(row: row)?.translateToString(trimRight: true) ?? ""
            while text.last == " " { text.removeLast() }
            return text
        }
        let lastText = all.lastIndex { !$0.isEmpty } ?? 0
        let end = min(rows, max(lastText, getCursorLocation().y) + 1)
        return Array(all[max(0, end - count)..<end])
    }
}

public extension Terminal {
    /// The last `limit` lines of scrollback plus screen as plain text, trailing blank lines dropped.
    /// Used by the phone's reader mode, where wrapping beats fidelity.
    func transcriptLines(limit: Int = 600) -> [String] {
        var lines: [String] = []
        var row = buffer.totalLinesTrimmed
        while let line = getScrollInvariantLine(row: row) {
            var text = line.translateToString(trimRight: true)
            while text.last == " " { text.removeLast() }
            lines.append(text)
            row += 1
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let firstText = lines.firstIndex { !$0.isEmpty } ?? lines.endIndex
        return Array(lines[firstText...].suffix(limit))
    }
}

/// Re-creates a terminal's visible state (plus some scrollback) as an escape-sequence stream, so a
/// remote client can bootstrap its own mirror and then follow the live byte stream.
public enum TerminalSnapshotEncoder {
    public static func encode(_ terminal: Terminal, scrollback: Int = 300) -> [UInt8] {
        var out = "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3J"
        let alternate = terminal.isCurrentBufferAlternate
        if alternate { out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J" }
        if terminal.applicationCursor { out += "\u{1b}[?1h" }

        let buffer = terminal.buffer
        let visibleTop = buffer.yDisp
        let firstRow = alternate ? visibleTop : max(0, visibleTop - scrollback)
        let lastRow = visibleTop + terminal.rows - 1
        var current = Attribute.empty
        for internalRow in firstRow...lastRow {
            guard let line = terminal.getScrollInvariantLine(row: internalRow + buffer.totalLinesTrimmed) else { continue }
            if internalRow > firstRow { out += "\u{1b}[0m\r\n"; current = .empty }
            // Trim trailing default blanks to keep the stream small.
            var end = min(terminal.cols, line.count)
            while end > 0, line[end - 1].attribute == .empty, line[end - 1].getCharacter() == " " || line[end - 1].getCharacter() == "\u{0}" {
                end -= 1
            }
            for col in 0..<end {
                let cell = line[col]
                if cell.width == 0 { continue }
                if cell.attribute != current {
                    out += sgr(cell.attribute)
                    current = cell.attribute
                }
                let ch = cell.getCharacter()
                out.append(ch == "\u{0}" ? " " : ch)
            }
        }
        let cursor = terminal.getCursorLocation()
        out += "\u{1b}[0m\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H"
        return Array(out.utf8)
    }

    static func sgr(_ a: Attribute) -> String {
        var p = ["0"]
        let s = a.style
        if s.contains(.bold) { p.append("1") }
        if s.contains(.dim) { p.append("2") }
        if s.contains(.italic) { p.append("3") }
        if s.contains(.underline) { p.append("4") }
        if s.contains(.blink) { p.append("5") }
        if s.contains(.inverse) { p.append("7") }
        if s.contains(.invisible) { p.append("8") }
        if s.contains(.crossedOut) { p.append("9") }
        p += color(a.fg, base: 30, bright: 90, extended: 38)
        p += color(a.bg, base: 40, bright: 100, extended: 48)
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, base: Int, bright: Int, extended: Int) -> [String] {
        switch c {
        case .ansi256(let code) where code < 8: return ["\(base + Int(code))"]
        case .ansi256(let code) where code < 16: return ["\(bright + Int(code) - 8)"]
        case .ansi256(let code): return ["\(extended)", "5", "\(code)"]
        case .trueColor(let r, let g, let b): return ["\(extended)", "2", "\(r)", "\(g)", "\(b)"]
        case .defaultColor, .defaultInvertedColor: return []
        }
    }
}
