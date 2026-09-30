import SwiftUI

/// The mark: four tiles, one of them lit — a board with something that needs you. In the app it is
/// drawn in ink: color is kept for state.
public struct TesseraGlyph: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let gap = max(1.5, geo.size.width * 0.08)
            let s = (geo.size.width - gap) / 2
            let r = s * 0.22
            ZStack(alignment: .topLeading) {
                Style.shape(r).fill(Style.ink.opacity(0.55)).frame(width: s, height: s)
                Style.shape(r).fill(Style.ink.opacity(0.35)).frame(width: s, height: s).offset(x: s + gap)
                Style.shape(r).fill(Style.ink.opacity(0.35)).frame(width: s, height: s).offset(y: s + gap)
                Style.shape(r).fill(Style.ink).frame(width: s, height: s).offset(x: s + gap, y: s + gap)
            }
        }
    }
}
