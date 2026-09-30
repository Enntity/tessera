import SwiftUI
import TesseraHost
import TesseraKit

/// The Needs-you lane, down the left of the board: everything waiting on the user, in the order ⌘J
/// visits it. It reads the queue alone; each row reads only its own tile.
struct AttentionLane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.workspace.state.queue
        VStack(spacing: 0) {
            // As tall as the tab strip beside it, so the first row lines up with the first row of tiles.
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Text(TileActivity.needsYouLabel).micro()
                if !queue.isEmpty {
                    Text("\(queue.count)").font(Style.caption).foregroundStyle(Style.muted).contentTransition(.numericText())
                }
                Spacer()
            }
            .foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.l)
            .frame(height: Style.Metrics.strip)
            .overlay(alignment: .bottom) { Hairline() }

            ScrollView {
                VStack(spacing: Style.Space.m) {
                    ForEach(queue, id: \.self) { id in
                        LaneRow(id: id, isNext: id == queue.first)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Style.Space.l)
            }
            .overlay(alignment: .top) {
                if queue.isEmpty {
                    VStack(spacing: Style.Space.m) {
                        Image(systemName: "checkmark.circle").font(Style.title).foregroundStyle(Style.faint)
                        Text("All caught up").font(Style.ui(.label, .medium)).foregroundStyle(Style.muted)
                    }
                    .padding(.top, Style.Space.xxl)
                    .transition(.opacity)
                }
            }
        }
        .chromeSurface(rule: .trailing)
        .animation(Style.Motion.standard, value: queue)
    }
}

/// One waiting tile: what it is, why it waits (its question, its error, what it finished with), and
/// for how long. A button: it opens the tile, as a click on the tile does. Under the pointer, a
/// terminal with a question grows a row of the answers a phone offers, typed into it unopened.
struct LaneRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy
    let id: String
    /// The first in the queue: where ⌘J goes.
    let isNext: Bool
    @State private var hovering = false

    var body: some View {
        if let info = model.workspace.info(id) {
            #if DEBUG
            let hovering = hovering || model.debugHover == id
            #endif
            VStack(alignment: .leading, spacing: 0) {
                Button { model.open(id) } label: {
                    VStack(alignment: .leading, spacing: Style.Space.xxs) {
                        HStack(spacing: Style.Space.xs) {
                            FlavorGlyph(info.flavor)
                            Text(info.title).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                            if info.activity == .done { Dot(Style.mint).padding(.leading, Style.Space.xxs) }
                            Spacer(minLength: Style.Space.xs)
                            // Under the pointer, the age makes way for the dismiss button over it.
                            Age(of: info.lastActivityAt).font(Style.caption).foregroundStyle(Style.muted).opacity(hovering ? 0 : 1)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: Style.Space.xs) {
                            Text(hidden(info) ? AttributedString(info.reason.obscured(true)) : info.reason.markdownPreview(120))
                                .foregroundStyle(info.activity == .done ? Style.muted : Style.state(info.activity))
                                // All of it under the pointer, where an answer may be about to be given.
                                .lineLimit(hovering ? 6 : 2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Style.Space.xs)
                            if isNext { Text("⌘J").foregroundStyle(Style.muted) }
                        }
                        .font(Style.caption)
                        // Under the title, past the glyph.
                        .padding(.leading, Style.Space.xl + Style.Space.xs)
                    }
                    .padding(.leading, Style.Space.s)
                    .padding(.trailing, Style.Space.m)
                    .padding(.vertical, Style.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if hovering, info.kind == .terminal, info.activity == .needsInput {
                    answers.padding(.horizontal, Style.Space.m).padding(.bottom, Style.Space.m)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { model.workspace.dismiss(id) } label: {
                        Image(systemName: "checkmark")
                            .font(Style.ui(.caption, .bold))
                            .frame(width: Style.Metrics.key, height: Style.Metrics.key)
                            .background(Style.Neutral.selected, in: Circle())
                            .foregroundStyle(Style.ink)
                    }
                    .buttonStyle(.plain)
                    .help(info.dismissLabel)
                    .padding(Style.Space.xs)
                    .transition(.opacity)
                }
            }
            .background(model.workspace.selectedId == id ? Style.Neutral.selected : hovering ? Style.Neutral.hover : .clear,
                        in: Style.shape(Style.Radius.m))
            .cardSurface()
            .help([info.title, hidden(info) ? nil : info.reason].compactMap { $0 }.joined(separator: "\n"))
            .onHover { self.hovering = $0 }
            .animation(Style.Motion.quick, value: hovering)
        }
    }

    /// In privacy mode, what a tile said (its question, its summary) is kept off the screen here as
    /// it is on the tile; how it failed is on show in both.
    private func hidden(_ info: TileInfo) -> Bool {
        privacy && info.detail != nil && info.activity != .failed
    }

    private var answers: some View {
        HStack(spacing: Style.Space.xs) {
            ForEach(QuickAnswer.allCases) { answer in
                Button { model.answer(id, with: answer) } label: {
                    Text(answer.label)
                        .font(Style.mono(.label, .bold))
                        .foregroundStyle(Style.amber)
                        .frame(maxWidth: .infinity)
                        .frame(height: Style.Metrics.key)
                        .background(Style.amber.opacity(answer == .enter ? Style.Tint.strong : Style.Tint.fill), in: Style.shape(Style.Radius.xs))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Type \(answer.label) into this terminal")
            }
        }
        .transition(.opacity)
    }
}
