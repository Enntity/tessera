import SwiftUI

/// The mark: four tiles, one of them lit amber — a board with something that needs you.
public struct TesseraGlyph: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let gap = max(1.5, geo.size.width * 0.08)
            let s = (geo.size.width - gap) / 2
            let r = s * 0.22
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: r).fill(Style.cyan).frame(width: s, height: s)
                RoundedRectangle(cornerRadius: r).fill(Style.cyan.opacity(0.55)).frame(width: s, height: s).offset(x: s + gap)
                RoundedRectangle(cornerRadius: r).fill(Style.cyan.opacity(0.35)).frame(width: s, height: s).offset(y: s + gap)
                RoundedRectangle(cornerRadius: r).fill(Style.amber).frame(width: s, height: s).offset(x: s + gap, y: s + gap)
            }
        }
    }
}
