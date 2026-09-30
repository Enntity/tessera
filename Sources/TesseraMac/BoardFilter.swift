import SwiftUI
import TesseraHost
import TesseraKit

/// The filter field, in the middle of the top bar. Anything typed on the board lands here and
/// narrows the board in place as it is typed: ⏎ opens the first tile found, the arrows move among
/// those found, Esc clears it and gives the keyboard back to the board.
struct FilterField: View {
    @Environment(AppModel.self) private var model
    @State private var focused = false

    var body: some View {
        let workspace = model.workspace
        let shape = Style.shape(Style.Radius.s)
        HStack(spacing: Style.Space.s) {
            Image(systemName: "magnifyingglass").font(Style.ui(.caption, .semibold)).foregroundStyle(focused ? Style.ink : Style.muted)
            FilterText(text: workspace.query.text, sets: workspace.textSets, focus: model.filterFocus, edited: model.filter(text:)) { key in
                switch key {
                case .open: if let id = workspace.selectedId { model.open(id) }
                case .clear: model.clearFilter()
                case .move(let step): model.move(step)
                }
            } focused: { on in
                focused = on
                model.isFiltering = on
            }
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
    }
}

/// The filter's text: AppKit's own field, so that the keyboard can be handed to it in the middle
/// of typing with the caret after what is already there, before the next key arrives. (A SwiftUI
/// field given the keyboard selects its text, and that key would replace it.)
struct FilterText: NSViewRepresentable {
    /// ⏎, Esc and the arrows: the board's, not the text's.
    enum Key { case open, clear, move(GridMove) }

    let text: String
    /// How many times the text has been set elsewhere (see `Workspace.textSets`).
    let sets: Int
    /// Bumped to take the keyboard.
    let focus: Int
    let edited: (String) -> Void
    let key: (Key) -> Void
    let focused: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        let font = NSFont.systemFont(ofSize: Style.TextSize.label.rawValue, weight: .medium)
        field.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        field.textColor = NSColor(Style.ink)
        field.placeholderAttributedString = NSAttributedString(string: "Type to filter", attributes: [
            .foregroundColor: NSColor(Style.muted), .font: field.font ?? font
        ])
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.focused = focused
        // The field is the text while it is typed in. Only a text set elsewhere (typed on the
        // board, cleared) is written into it, and once: an update can arrive after a later key.
        if coordinator.sets != sets {
            coordinator.sets = sets
            field.stringValue = text
        }
        guard coordinator.focus != focus else { return }
        coordinator.focus = focus
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    /// As wide as it is given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Style.Metrics.filterMin, height: field.intrinsicContentSize.height)
    }

    /// Says when it takes and gives up the keyboard, once the view update it may be part of is over.
    final class Field: NSTextField {
        var focused: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { DispatchQueue.main.async { [self] in focused?(true) } }
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            DispatchQueue.main.async { [self] in focused?(false) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterText
        var sets: Int
        var focus: Int

        init(_ parent: FilterText) {
            self.parent = parent
            sets = parent.sets
            focus = parent.focus
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.edited(field.stringValue) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let keys: [Selector: Key] = [
                #selector(NSResponder.insertNewline(_:)): .open, #selector(NSResponder.cancelOperation(_:)): .clear,
                #selector(NSResponder.moveUp(_:)): .move(.up), #selector(NSResponder.moveDown(_:)): .move(.down),
                #selector(NSResponder.moveLeft(_:)): .move(.left), #selector(NSResponder.moveRight(_:)): .move(.right)
            ]
            guard let key = keys[selector] else { return false }
            parent.key(key)
            return true
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

    // (Left to the protocol, an alignment guide is found by placing everything, on every question.)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let gap = Style.Space.l
        // What each side is given is what the other leaves, less the field at its narrowest.
        let room = bounds.width - Style.Metrics.filterMin - 2 * gap
        func fit(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
            subview.sizeThatFits(ProposedViewSize(width: max(width, 0), height: bounds.height))
        }
        var leading = fit(subviews[0], width: room)
        var trailing = fit(subviews[2], width: room - leading.width)
        // Only when they don't both fit whole is there anything to weigh.
        if leading.width + fit(subviews[2], width: room).width > room {
            let bare = fit(subviews[2], width: 0).width
            leading = fit(subviews[0], width: room - bare)
            if fit(subviews[2], width: room - leading.width).width == bare {
                let short = fit(subviews[0], width: 0)
                if fit(subviews[2], width: room - short.width).width > bare { leading = short }
            }
            trailing = fit(subviews[2], width: room - leading.width)
        }
        let width = min(Style.Metrics.filter, max(bounds.width - leading.width - trailing.width - 2 * gap, 0))
        let x = min(max(bounds.midX - width / 2, bounds.minX + leading.width + gap), bounds.maxX - trailing.width - gap - width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
    }
}
