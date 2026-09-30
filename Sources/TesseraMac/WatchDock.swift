import SwiftUI
import TesseraHost
import TesseraKit

/// The watch dock, between the board and the accounts: up to two tiles kept open, live, to be
/// watched and typed into while the board carries on beside them. A tile dropped on it is docked.
/// It reads which tiles are docked; each panel reads only its own tile.
struct WatchDockColumn: View {
    @Environment(AppModel.self) private var model
    /// How wide it is on show, and how wide it can be made (see `BoardColumns`).
    let width: CGFloat
    let widest: CGFloat
    @State private var targeted = false

    var body: some View {
        let ids = model.workspace.docked
        VStack(spacing: 0) {
            // As tall as the tab strip beside it, so the first panel lines up with the first row of tiles.
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Text("Watch").micro()
                Text("\(ids.count)").font(Style.caption).foregroundStyle(Style.muted).contentTransition(.numericText())
                Spacer()
                Text("⌘D").font(Style.caption).foregroundStyle(Style.muted)
            }
            .foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.l)
            .frame(height: Style.Metrics.strip)
            .overlay(alignment: .bottom) { Hairline() }

            VStack(spacing: Style.Space.gutter) {
                ForEach(ids, id: \.self) { id in
                    DockPanel(id: id).transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(Style.Space.l)
        }
        .chromeSurface(rule: .leading)
        .overlay { if targeted { Rectangle().strokeBorder(Style.Neutral.focus, lineWidth: Style.Metrics.edge).allowsHitTesting(false) } }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in providers.loadTileId { model.setDocked($0, true) } }
        .overlay(alignment: .leading) { DockGrip(width: width, widest: widest) }
        .animation(Style.Motion.standard, value: ids)
    }
}

/// The dock's leading edge, dragged to make it wider or narrower. The width is kept with the board.
private struct DockGrip: View {
    @Environment(AppModel.self) private var model
    /// How wide the dock is on show (a drag starts from there), and the widest a drag makes it.
    let width: CGFloat
    let widest: CGFloat
    @State private var hovering = false
    /// How wide the dock was when the drag began.
    @State private var from: CGFloat?

    var body: some View {
        let grip = Style.Metrics.grip
        Capsule().fill(hovering || from != nil ? Style.Neutral.focus : Style.Neutral.border)
            .frame(width: Style.Space.xs, height: grip.height)
            .frame(maxHeight: .infinity)
            .frame(width: grip.width)
            .contentShape(Rectangle())
            // Astride the rule it moves.
            .offset(x: -grip.width / 2)
            .onHover { over in
                hovering = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("window"))
                .onChanged { drag in
                    let start = from ?? width
                    from = start
                    model.workspace.dockWidth = min(max(start - drag.translation.width, Style.Metrics.dockMin), widest)
                }
                .onEnded { _ in
                    from = nil
                    model.workspace.save()
                })
            .animation(Style.Motion.quick, value: hovering)
            .help("Drag to resize the dock")
    }
}

/// A docked tile: a compact header over its live content. The keyboard is in it when its edge is lit.
struct DockPanel: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let info = model.workspace.info(id) {
            let shape = Style.shape(Style.Radius.l)
            VStack(spacing: 0) {
                DockHeader(info: info)
                LiveContent(info: info, docked: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Style.deck)
            .clipShape(shape)
            .overlay(shape.strokeBorder(model.keyboardDock == id ? Style.Neutral.focus : Style.Neutral.border).allowsHitTesting(false))
            .elevation(.tile)
        }
    }
}

/// Glyph, title and state, then what can be done with a docked tile: its menu, open it full size,
/// take it out of the dock. A click on the header gives its terminal or page the keyboard.
struct DockHeader: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    @State private var renaming = false

    var body: some View {
        HStack(spacing: Style.Space.gutter) {
            Button { model.open(info.id, inApp: false) } label: {
                HStack(spacing: Style.Space.xs) {
                    Image(systemName: info.flavor.symbol)
                        .font(Style.ui(.caption, .semibold))
                        .foregroundStyle(Style.accent(info.flavor))
                        .frame(width: Style.Space.xl)
                    Text(info.title).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                    if info.activity == .done, info.attention { Dot(Style.mint).padding(.leading, Style.Space.xxs) }
                    Spacer(minLength: Style.Space.xs)
                    StatePill(activity: info.activity)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .help([info.title, info.subtitle].filter { !$0.isEmpty }.joined(separator: "\n"))
            Menu {
                TileMenu(info: info, inPanel: true) { renaming = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Style.dim)
            .fixedSize()
            .help("More")
            .modifier(RenamePopover(info: info, isPresented: $renaming))
            Button { model.expand(info.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Open full size")
            Button { model.setDocked(info.id, false) } label: { Image(systemName: "xmark") }
                .help("Undock (⌘D)")
        }
        .buttonStyle(.plain)
        .font(Style.ui(.label))
        .foregroundStyle(Style.dim)
        .padding(.leading, Style.Space.m)
        .padding(.trailing, Style.Space.l)
        .frame(height: Style.Metrics.dockHeader)
        .background(Style.glass)
        .overlay(alignment: .bottom) { Hairline() }
        .contextMenu { TileMenu(info: info, inPanel: true) { renaming = true } }
    }
}
