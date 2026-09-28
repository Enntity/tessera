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

    /// Top-left origin of tile `index`, with the whole grid centred in `size`.
    public func origin(of index: Int, in size: CGSize) -> CGPoint {
        let col = index % max(columns, 1)
        let row = index / max(columns, 1)
        let usedW = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing
        let usedH = CGFloat(rows) * tileSize.height + CGFloat(max(rows - 1, 0)) * spacing
        let x0 = max(0, (size.width - usedW) / 2)
        let y0 = scrolls ? 0 : max(0, (size.height - usedH) / 2)
        return CGPoint(x: x0 + CGFloat(col) * (tileSize.width + spacing),
                       y: y0 + CGFloat(row) * (tileSize.height + spacing))
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
