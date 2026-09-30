import SwiftUI
import TesseraHost
import TesseraKit

/// The filter field, in the middle of the top bar. Anything typed on the board lands here and
/// narrows the board in place as it is typed: ⏎ opens the first tile found, the arrows move among
/// those found, Esc clears it and gives the keyboard back to the board.
struct FilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let workspace = model.workspace
        let shape = Style.shape(Style.Radius.s)
        HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
            Image(systemName: "magnifyingglass").font(Style.ui(.caption, .semibold)).foregroundStyle(focused ? Style.ink : Style.muted)
            TextField("Type to filter", text: Binding { workspace.query.text } set: { model.filter(text: $0) })
                .textFieldStyle(.plain)
                .font(Style.ui(.label, .medium))
                .foregroundStyle(Style.ink)
                .focused($focused)
                .onSubmit { if let id = workspace.selectedId { model.open(id) } }
            if !workspace.query.isEmpty {
                Text("\(workspace.visibleIds.count)").font(Style.caption).foregroundStyle(Style.muted).contentTransition(.numericText())
                Button { model.clearFilter() } label: { Image(systemName: "xmark.circle.fill").font(Style.label) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Style.muted)
                    .help("Show every tile again (Esc)")
            }
        }
        .padding(.horizontal, Style.Space.m)
        .frame(height: Style.Metrics.control)
        .background(Style.Neutral.hover, in: shape)
        .overlay(shape.strokeBorder(focused ? Style.Neutral.focus : Style.Neutral.border))
        .contentShape(Rectangle())
        .onTapGesture { model.beginFilter() }
        .onChange(of: model.filterFocus) {
            focused = true
            // A field given the keyboard selects what it holds; what is typed next must add to it.
            DispatchQueue.main.async { (model.window?.firstResponder as? NSText)?.moveToEndOfLine(nil) }
        }
        .onChange(of: focused) { _, on in model.isFiltering = on }
        .onKeyPress(.escape) {
            model.clearFilter()
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            model.move([.upArrow: .up, .downArrow: .down, .leftArrow: .left][press.key] ?? .right)
            return .handled
        }
    }
}

/// The filter's chips, at the right of the tab strip: states, then kinds, each with how many tiles
/// it would show. A chip is there while it has something to narrow (some of the tiles there are to
/// show, not all of them) or is on; they drop their labels, then go, as room runs out.
struct FilterChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        let total = workspace.findable
        let chips = BoardQuery.Chip.allCases.compactMap { chip -> (chip: BoardQuery.Chip, count: Int, on: Bool)? in
            let count = workspace.count(chip), on = workspace.query.chips.contains(chip)
            return on || (count > 0 && count < total) ? (chip, count, on) : nil
        }
        ViewThatFits(in: .horizontal) {
            ForEach([true, false], id: \.self) { labelled in
                HStack(spacing: Style.Space.xs) {
                    ForEach(chips, id: \.chip) { chip, count, on in
                        TabChip(title: chip.label, count: count, waiting: chip.activity, flavor: chip.flavor,
                                selected: on, outlined: true, labelled: labelled) { model.toggle(chip) }
                            .help("Show only \(chip.label)")
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.trailing, Style.Space.l)
            }
            Color.clear.frame(width: 0)
        }
        .animation(Style.Motion.standard, value: chips.map(\.chip))
    }
}

/// The top bar's three parts: what is going on at the left, the filter field, and what can be
/// watched and started at the right. The field sits in the middle of the window and stays there
/// whatever the parts beside it do; only when one of them reaches it does it give way, then narrow.
/// As room runs out the machine chips go compact, then the counters lose their words so that the
/// chips can stay, and last the chips go.
struct HUDLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let gap = Style.Space.l
        // What each side is given is what the other leaves, less the field at its narrowest.
        let room = bounds.width - Style.Metrics.filterMin - 2 * gap
        func fit(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
            subview.sizeThatFits(ProposedViewSize(width: max(width, 0), height: bounds.height))
        }
        let bare = fit(subviews[2], width: 0).width
        var leading = fit(subviews[0], width: room - bare)
        if fit(subviews[2], width: room - leading.width).width == bare {
            let short = fit(subviews[0], width: 0)
            if fit(subviews[2], width: room - short.width).width > bare { leading = short }
        }
        let trailing = fit(subviews[2], width: room - leading.width)
        let width = min(Style.Metrics.filter, max(bounds.width - leading.width - trailing.width - 2 * gap, 0))
        let x = min(max(bounds.midX - width / 2, bounds.minX + leading.width + gap), bounds.maxX - trailing.width - gap - width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
    }
}
