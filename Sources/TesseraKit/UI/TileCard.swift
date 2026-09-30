import SwiftUI

/// The chrome around every tile: what it is (glyph, title), where it lives and how long ago it
/// last did anything (the footer), and its state, which reads the same at every size:
/// - idle: nothing;
/// - working: a pill, and a highlight sweeping the rule under the header (or the progress the
///   program reports);
/// - needs you: a pill, an amber edge with a glow, and the question called out over the content;
/// - done, not yet seen: a dot after the title and a faint edge;
/// - failed: a pill, a coral edge (fainter once seen), and why in the footer;
/// - selected: a ring outside the edge, whatever the state.
public struct TileCard<Content: View>: View {
    @Environment(\.tesseraPrivacy) private var privacy
    @Environment(\.tesseraHighlight) private var highlight
    let info: TileInfo
    let isSelected: Bool
    let isHovered: Bool
    let compact: Bool
    /// A quiet symbol in the header for where else the tile is on show (the Mac's dock).
    let mark: String?
    let content: Content

    public init(info: TileInfo, isSelected: Bool = false, isHovered: Bool = false, compact: Bool = false, mark: String? = nil,
                @ViewBuilder content: () -> Content) {
        self.info = info
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.compact = compact
        self.mark = mark
        self.content = content()
    }

    public static func headerHeight(compact: Bool) -> CGFloat { compact ? 22 : 26 }
    static func footerHeight(compact: Bool) -> CGFloat { compact ? 18 : 20 }

    public var body: some View {
        let shape = Style.shape(Style.Radius.m)
        let edge = self.edge
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .bottom) { question }
            footer
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(edge.color, lineWidth: edge.width) }
        .overlay {
            if isSelected {
                let ring = Style.Metrics.ring
                Style.shape(Style.Radius.m + 2 * ring).strokeBorder(Style.ink, lineWidth: ring).padding(-2 * ring)
            }
        }
        // The shadow sits on a still shape behind the card, so nothing above ever re-renders it.
        .background {
            shape.fill(Style.terminalBackground)
                .elevation(info.activity == .needsInput ? .attention(Style.amber) : .tile)
        }
        .contentShape(Rectangle())
        // The whole title, which a narrow tile cuts short, and what the tile last said (not in
        // privacy mode, where that is kept off the screen).
        .help([info.title, privacy ? nil : info.detail].compactMap { $0 }.joined(separator: "\n"))
    }

    /// The tile's outline: a state that waits on the user lights it, otherwise it is a quiet
    /// border that lifts under the pointer.
    private var edge: (color: Color, width: CGFloat) {
        let color = Style.state(info.activity)
        switch info.activity {
        case .needsInput: return (color, Style.Metrics.edge)
        case .failed where info.attention: return (color, Style.Metrics.edge)
        case .failed: return (color.opacity(Style.Tint.stroke), 1)
        case .done where info.attention: return (color.opacity(Style.Tint.stroke), 1)
        default: return (isHovered ? Style.Neutral.borderHover : Style.Neutral.border, 1)
        }
    }

    private var header: some View {
        HStack(spacing: Style.Space.xs) {
            FlavorGlyph(info.flavor)
            Text(lit(info.title))
                .font(Style.label)
                .foregroundStyle(Style.ink)
                .lineLimit(1)
            if info.activity == .done, info.attention {
                Dot(Style.mint).padding(.leading, Style.Space.xxs)
            }
            Spacer(minLength: Style.Space.xs)
            if let mark { Image(systemName: mark).font(Style.ui(.caption)).foregroundStyle(Style.muted) }
            StatePill(activity: info.activity)
        }
        .padding(.leading, Style.Space.s)
        .padding(.trailing, Style.Space.m)
        .frame(height: Self.headerHeight(compact: compact))
        .overlay(alignment: .bottom) { rule }
    }

    /// The title or the folder, lit where it has what the board's filter is looking for.
    private func lit(_ text: String) -> AttributedString {
        var lit = AttributedString(text)
        for found in TileSearch.ranges(of: highlight, in: text) {
            if let range = Range(found, in: lit) { lit[range].backgroundColor = Style.Neutral.found }
        }
        return lit
    }

    /// The rule under the header. While the tile works it carries the sweep, or, when the program
    /// says how far along it is, that.
    private var rule: some View {
        Hairline().overlay {
            if let progress = info.progress {
                Style.cyan.opacity(Style.Tint.stroke)
                Style.cyan.scaleEffect(x: progress, anchor: .leading).animation(Style.Motion.data, value: progress)
            } else if info.activity == .working {
                Style.cyan.opacity(Style.Tint.stroke)
                Ambient(.sweep(Style.cyan))
            }
        }
    }

    /// What a waiting tile is asking, over the bottom of its content.
    @ViewBuilder
    private var question: some View {
        if info.activity == .needsInput, let detail = info.detail {
            let box = Style.shape(Style.Radius.s)
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Image(systemName: "questionmark.circle")
                Text(privacy ? AttributedString(detail.obscured(true)) : detail.markdownPreview(160))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Style.caption)
            .foregroundStyle(Style.amber)
            .padding(.horizontal, Style.Space.m)
            .padding(.vertical, Style.Space.s)
            .background { box.fill(Style.terminalBackground).overlay(box.fill(Style.amber.opacity(Style.Tint.fill))) }
            .overlay(box.strokeBorder(Style.amber.opacity(Style.Tint.stroke)))
            .padding(Style.Space.s)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
            // A long path keeps its end: the folder itself.
            Text(lit(info.subtitle)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: Style.Space.xs)
            if info.activity == .failed, let detail = info.detail {
                Text(detail).foregroundStyle(Style.coral).lineLimit(1)
            }
            Age(of: info.lastActivityAt)
        }
        .font(Style.caption)
        .foregroundStyle(Style.muted)
        .padding(.horizontal, Style.Space.m)
        .frame(height: Self.footerHeight(compact: compact))
        .overlay(alignment: .top) { Hairline() }
    }
}

public extension View {
    /// The margin a terminal's thumbnail keeps on its tile, so text never touches the edge or the
    /// corner. Applied where the tile is built, not in the thumbnail: privacy mode lays the same
    /// thumbnail over a live terminal, edge to edge.
    func terminalTileInset() -> some View {
        padding(.horizontal, Style.Space.m).padding(.vertical, Style.Space.xs)
    }
}

/// A tile's state in words, for the states worth a word: idle tiles, and results (which get a
/// dot), go without.
public struct StatePill: View {
    let activity: TileActivity

    public init(activity: TileActivity) { self.activity = activity }

    public var body: some View {
        switch activity {
        case .working, .needsInput, .failed, .exited:
            let color = Style.state(activity)
            Text(activity.label).micro()
                .foregroundStyle(color)
                .padding(.horizontal, Style.Space.s)
                .padding(.vertical, Style.Space.xxs)
                .background(color.opacity(Style.Tint.fill), in: Capsule())
                .fixedSize()
        case .starting, .idle, .done:
            EmptyView()
        }
    }
}
