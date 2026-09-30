import CoreGraphics

/// Packs N equal tiles into a region, maximising tile area (the video-wall problem).
public struct GridLayout: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var tileSize: CGSize
    public var spacing: CGFloat
    /// True when tiles hit `minTileWidth` and the grid must scroll vertically.
    public var scrolls: Bool

    public static func fit(count: Int, in size: CGSize, spacing: CGFloat = 10,
                           aspect: CGFloat = 16.0 / 10.0, minTileWidth: CGFloat = 200) -> GridLayout {
        guard count > 0, size.width > 0, size.height > 0 else {
            return GridLayout(columns: 1, rows: 0, tileSize: .zero, spacing: spacing, scrolls: false)
        }
        var best = GridLayout(columns: 1, rows: count, tileSize: .zero, spacing: spacing, scrolls: false)
        var bestArea: CGFloat = -1
        for cols in 1...count {
            let rows = (count + cols - 1) / cols
            var w = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            var h = w / aspect
            let totalH = CGFloat(rows) * h + CGFloat(rows - 1) * spacing
            if totalH > size.height {
                h = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
                w = h * aspect
            }
            guard w > 0, h > 0 else { continue }
            let area = w * h
            if area > bestArea + 0.5 {
                bestArea = area
                best = GridLayout(columns: cols, rows: rows, tileSize: CGSize(width: w, height: h), spacing: spacing, scrolls: false)
            }
        }
        if best.tileSize.width < minTileWidth {
            let cols = max(1, Int((size.width + spacing) / (minTileWidth + spacing)))
            let w = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            return GridLayout(columns: cols, rows: (count + cols - 1) / cols,
                              tileSize: CGSize(width: w, height: w / aspect), spacing: spacing, scrolls: true)
        }
        return best
    }

    /// Top-left origin of tile `index`: the grid starts at the top of `size`, centred across it, so
    /// the first row lines up with what is beside the board and any room left over is below.
    public func origin(of index: Int, in size: CGSize) -> CGPoint {
        let col = index % max(columns, 1)
        let row = index / max(columns, 1)
        let usedW = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing
        let x0 = max(0, (size.width - usedW) / 2)
        return CGPoint(x: x0 + CGFloat(col) * (tileSize.width + spacing),
                       y: CGFloat(row) * (tileSize.height + spacing))
    }

    /// The middle, across `width`, of the column nearest the middle of the grid (of two as near, the
    /// left one). What is laid over the last row there sits between a footer's two ends, where
    /// nothing is written, rather than across the ends of two.
    public func middleColumnCenter(in width: CGFloat) -> CGFloat {
        guard tileSize.width > 0 else { return width / 2 }
        let x = origin(of: (max(columns, 1) - 1) / 2, in: CGSize(width: width, height: 0)).x
        return x + tileSize.width / 2
    }

    public var contentHeight: CGFloat {
        CGFloat(rows) * tileSize.height + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// Where a tile opens: as large as `preferred` allows, centred on the tile, kept inside `bounds`,
    /// so the eye stays where the tile was.
    public static func expandedFrame(from tile: CGRect, in bounds: CGRect, preferred: CGSize) -> CGRect {
        let w = min(preferred.width, bounds.width)
        let h = min(preferred.height, bounds.height)
        var x = tile.midX - w / 2
        var y = tile.midY - h / 2
        x = min(max(x, bounds.minX), bounds.maxX - w)
        y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// An open panel part-way between its tile and its open frame. It is laid out at its open size and
/// scaled down, by one factor for both axes so nothing inside is stretched; on its tile that leaves
/// it wider or taller than the tile, so only `shown` of it is on show, which makes the tile's shape.
public struct PanelZoom: Equatable, Sendable {
    public var scale: CGFloat
    /// How much of the panel (at its open size, before scaling) is on show.
    public var shown: CGSize
    /// Where the scaled panel's top-left corner is.
    public var origin: CGPoint

    /// `progress` runs from 0 (on the tile) to 1 (open); a spring may take it a little past 1, which
    /// the scale and place follow and `shown` doesn't.
    public init(from tile: CGRect, to open: CGRect, progress: CGFloat) {
        // (Nothing to scale before the board has any room.)
        let start = tile.isEmpty || open.isEmpty ? 1 : max(tile.width / open.width, tile.height / open.height)
        func between(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let reveal = min(progress, 1)
        scale = between(start, 1, progress)
        shown = CGSize(width: between(tile.width / start, open.width, reveal), height: between(tile.height / start, open.height, reveal))
        origin = CGPoint(x: between(tile.minX, open.minX, progress), y: between(tile.minY, open.minY, progress))
    }
}

/// A step of the selection across the grid.
public enum GridMove: Sendable {
    case left, right, up, down
    /// Through every tile in order, round and round (⌘[ ⌘]).
    case previous, next
}

public extension GridLayout {
    /// The tile a move from `index` lands on among `count` tiles, or nil when there is nowhere to go.
    /// Arrows stop at the edges; ↓ above a short last row lands on its last tile. With nothing
    /// selected, a move starts at the first tile (`previous`: the last).
    func index(moving move: GridMove, from index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index < count else { return move == .previous ? count - 1 : 0 }
        let cols = max(columns, 1)
        let target: Int
        switch move {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - cols
        case .down: target = index / cols < (count - 1) / cols ? min(index + cols, count - 1) : count
        case .previous: target = (index + count - 1) % count
        case .next: target = (index + 1) % count
        }
        return (0..<count).contains(target) && target != index ? target : nil
    }

    /// How far a view `height` tall must be scrolled to show all of tile `index`: `current` when it
    /// already does, otherwise the nearest offset that does.
    func scrollOffset(showing index: Int, height: CGFloat, current: CGFloat) -> CGFloat {
        guard scrolls else { return 0 }
        let top = CGFloat(index / max(columns, 1)) * (tileSize.height + spacing)
        let offset = min(top, max(current, top + tileSize.height - height))
        return min(max(offset, 0), max(contentHeight - height, 0))
    }
}
