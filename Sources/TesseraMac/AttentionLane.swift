import SwiftUI
import TesseraHost
import TesseraKit

/// The Needs-you lane, down the left of the board: everything waiting on the user, split into what
/// it wants — a question with its answers right there, a failure with its remedies, results to
/// review — in the order ⌘J visits it. It reads the queue alone; each row reads only its own tile.
struct AttentionLane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy

    var body: some View {
        let state = model.workspace.state
        let steward = model.workspace.steward
        // The queue keeps its ⌘J order inside each section, most pressing first.
        let asking = state.queue.filter { state.needsInput.contains($0) }
        let failed = state.queue.filter { state.failed.contains($0) }
        let review = state.queue.filter { state.done.contains($0) }
        VStack(spacing: 0) {
            // As tall as the tab strip beside it, so the first row lines up with the first row of tiles.
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Text(TileActivity.needsYouLabel).micro()
                let calling = state.needsInput.count + state.failed.count
                if calling > 0 {
                    Text("\(calling)").font(Style.caption).foregroundStyle(Style.muted).contentTransition(.numericText())
                        .help("\(calling) asking or failed · \(state.done.count) to review")
                }
                Spacer()
                if !state.queue.isEmpty {
                    Button { model.openTriage() } label: { Image(systemName: "rectangle.stack") }
                        .buttonStyle(.plain).foregroundStyle(Style.muted).help("Triage one at a time (⇧⌘J)")
                }
                if steward.config.enabled { stewardStatus(steward) }
            }
            .foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.l)
            .frame(height: Style.Metrics.strip)
            .overlay(alignment: .bottom) { Hairline() }

            ScrollView {
                VStack(alignment: .leading, spacing: Style.Space.m) {
                    if steward.config.enabled, let brief = steward.brief, !brief.headline.isEmpty {
                        HStack(alignment: .top, spacing: Style.Space.xs) {
                            Image(systemName: "sparkles").font(Style.caption).foregroundStyle(Style.accent(.agentDesk))
                            // Plain text: the model read untrusted screens, so nothing it writes becomes a link.
                            Text(brief.headline.obscured(privacy))
                                .font(Style.caption).foregroundStyle(Style.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Asking", ids: asking) { id in AskRow(id: id, isNext: id == state.queue.first) }
                    section("Failed", ids: failed) { id in FailedRow(id: id, isNext: id == state.queue.first) }
                    section("To review", ids: review, trailing: {
                        Button("Mark all seen") { for id in review { model.workspace.dismiss(id) } }
                            .font(Style.caption).buttonStyle(.borderless)
                            .help("Take every result here out of the queue")
                    }) { id in
                        ReviewRow(id: id, isNext: id == state.queue.first)
                    }
                    ClosableSection()
                    if state.queue.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: Style.Space.m) {
                                Image(systemName: "checkmark.circle").font(Style.title).foregroundStyle(Style.faint)
                                Text("All caught up").font(Style.ui(.label, .medium)).foregroundStyle(Style.muted)
                            }
                            Spacer()
                        }
                        .padding(.top, Style.Space.xxl)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Style.Space.l)
            }
        }
        .chromeSurface(rule: .trailing)
        .animation(Style.Motion.standard, value: state.queue)
    }

    /// The steward's own state, on the header's right: reading, failed, or ready to brief again.
    @ViewBuilder private func stewardStatus(_ steward: StewardService) -> some View {
        switch steward.status {
        case .thinking: ProgressView().controlSize(.mini)
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Style.coral).help(why)
        default:
            Button { steward.refresh() } label: { Image(systemName: "sparkles") }
                .buttonStyle(.plain).foregroundStyle(Style.muted).help("Brief again now")
        }
    }

    /// One labelled run of rows (ASKING, FAILED, TO REVIEW), only while it has any.
    @ViewBuilder private func section<Row: View, Trailing: View>(_ label: String, ids: [String],
                                                    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
                                                    @ViewBuilder row: @escaping (String) -> Row) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: Style.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).micro()
                    Text("\(ids.count)").font(Style.caption)
                    Spacer()
                    trailing()
                }
                .foregroundStyle(Style.muted)
                .padding(.horizontal, Style.Space.s)
                VStack(spacing: Style.Space.m) {
                    ForEach(ids, id: \.self) { id in
                        row(id).transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
        }
    }
}

/// The card chrome every lane row shares: click the text to open the tile; under the pointer a
/// checkmark takes it out of the queue and the age makes way for it. `line` is what sits under the
/// title; `footer` is controls that must not open the tile (answers, remedies).
struct LaneCard<Line: View, Footer: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy
    let id: String
    /// The first in the queue: where ⌘J goes.
    var isNext = false
    /// A lit edge, for rows that block.
    var border: Color?
    /// The tile, whether the pointer is over the row, and whether privacy keeps its words off.
    @ViewBuilder var line: (TileInfo, Bool, Bool) -> Line
    @ViewBuilder var footer: (TileInfo) -> Footer
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
                            Text(info.title)
                                .font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                            Spacer(minLength: Style.Space.xs)
                            // Under the pointer, the age makes way for the dismiss button over it.
                            Age(of: info.lastActivityAt).font(Style.caption).foregroundStyle(Style.muted).opacity(hovering ? 0 : 1)
                        }
                        // Under the title, past the glyph.
                        line(info, hovering, hidden(info))
                            .padding(.leading, Style.Space.xl + Style.Space.xs)
                    }
                    .padding(.leading, Style.Space.s)
                    .padding(.trailing, Style.Space.m)
                    .padding(.vertical, Style.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if Footer.self != EmptyView.self {
                    footer(info).padding(.horizontal, Style.Space.m).padding(.bottom, Style.Space.m)
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
            .overlay(alignment: .bottomTrailing) {
                if isNext { Text("⌘J").font(Style.caption).foregroundStyle(Style.muted).padding(.trailing, Style.Space.m).padding(.bottom, Style.Space.xs) }
            }
            .background(model.workspace.selectedId == id ? Style.Neutral.selected : hovering ? Style.Neutral.hover : .clear,
                        in: Style.shape(Style.Radius.m))
            .cardSurface()
            .overlay {
                if let border { Style.shape(Style.Radius.m).strokeBorder(border) }
            }
            .help([info.title, hidden(info) ? nil : info.laneLine].compactMap { $0 }.joined(separator: "\n"))
            .onHover { self.hovering = $0 }
            .animation(Style.Motion.quick, value: hovering)
        }
    }

    /// In privacy mode, what a tile said is kept off the screen here as it is on the tile; how it
    /// failed is on show in both.
    func hidden(_ info: TileInfo) -> Bool { privacy && info.activity != .failed }
}

extension LaneCard where Footer == EmptyView {
    init(id: String, isNext: Bool = false, border: Color? = nil, @ViewBuilder line: @escaping (TileInfo, Bool, Bool) -> Line) {
        self.init(id: id, isNext: isNext, border: border, line: line) { _ in EmptyView() }
    }
}

/// What the tile's own line reads as: a question or failure speaks in its color, a result in dim.
private func laneText(_ info: TileInfo, line: String? = nil, color: Color, limit: Int, hidden: Bool) -> some View {
    let line = line ?? info.laneLine
    return Text(hidden ? AttributedString(line.obscured(true)) : line.markdownPreview(120))
        .font(Style.caption).foregroundStyle(color)
        .lineLimit(limit)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
}

/// A finished tile with nothing said about it still has its own last line; ask the tile for it
/// only then — reading a tile's text is not free.
@MainActor
func shownLaneLine(_ info: TileInfo, _ workspace: Workspace) -> String {
    info.laneLine(shown: info.needs == nil && info.summary == nil && info.detail == nil
        ? workspace.shownText(info.id, lines: 8) : nil)
}

/// A tile asking: its question in its own words, bordered amber as blocking, with the answers right
/// there — the phone's one-tap keys for a terminal, the agent's own options for a desk question.
struct AskRow: View {
    let id: String
    let isNext: Bool

    var body: some View {
        LaneCard(id: id, isNext: isNext, border: Style.amber.opacity(Style.Tint.stroke)) { info, _, hidden in
            laneText(info, color: Style.ink, limit: 6, hidden: hidden)
        } footer: { info in
            if info.kind == .terminal { QuickAnswers(id: id).padding(.top, Style.Space.xs) }
            // An agent's question or message waits here for its answer, pointer or not.
            if info.flavor == .agentDesk { DeskAnswers(id: id).padding(.top, Style.Space.xs) }
        }
    }
}

/// The phone's one-tap answers, typed into a terminal unopened: the lane's asking row and the
/// triage card both offer them, so the look lives here once.
struct QuickAnswers: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
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
    }
}

/// A tile that failed: why, in coral, and what can be done about it — restart it, or just mark it
/// seen — without opening it.
struct FailedRow: View {
    @Environment(AppModel.self) private var model
    let id: String
    let isNext: Bool

    var body: some View {
        LaneCard(id: id, isNext: isNext) { info, _, _ in
            laneText(info, color: Style.coral, limit: 3, hidden: false)
        } footer: { info in
            HStack(spacing: Style.Space.xs) {
                if let action = model.actions(for: info).first {
                    actionButton(action.title, color: Style.coral) { action.run() }
                }
                actionButton("Mark as Seen", color: Style.dim) { model.workspace.dismiss(info.id) }
                Spacer(minLength: 0)
            }
            .padding(.top, Style.Space.xs)
        }
    }

    private func actionButton(_ title: String, color: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(Style.ui(.caption, .semibold)).lineLimit(1)
                .foregroundStyle(color)
                .padding(.horizontal, Style.Space.s)
                .frame(height: Style.Metrics.key)
                .background(color.opacity(Style.Tint.fill), in: Style.shape(Style.Radius.xs))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A finished tile to look over: compact — one line of what the steward says to do with it, or what
/// it did; under the pointer a few more.
struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let id: String
    let isNext: Bool

    var body: some View {
        LaneCard(id: id, isNext: isNext) { info, hovering, hidden in
            laneText(info, line: shownLaneLine(info, model.workspace), color: Style.dim, limit: hovering ? 5 : 2, hidden: hidden)
        }
    }
}

/// What the steward says could be closed or hidden: collapsed to a count, its rows under a chevron,
/// "Close all" in the header with Undo bringing them back.
struct ClosableSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy
    @State private var showClosable = false

    var body: some View {
        let steward = model.workspace.steward
        if steward.config.enabled, let brief = steward.brief {
            let closable = brief.closable.filter { item in
                !privacy && !steward.dismissed.contains(item.id) && canClose(item.id)
            }
            if !closable.isEmpty {
                VStack(alignment: .leading, spacing: Style.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Can be put away").micro()
                        Text("\(closable.count)").font(Style.caption)
                        Spacer()
                        Button("Close all") {
                            let current = closable.filter { canClose($0.id) }
                            for item in current { model.workspace.steward.record("closed", tile: item.id, why: item.why) }
                            model.close(current.map(\.id))
                        }
                        .font(Style.caption).buttonStyle(.borderless)
                        .help("Close or hide these tiles (Undo brings them back)")
                        Button { withAnimation(Style.Motion.quick) { showClosable.toggle() } } label: {
                            Image(systemName: showClosable ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Style.muted)
                    .padding(.horizontal, Style.Space.s)
                    if showClosable {
                        VStack(spacing: Style.Space.xs) {
                            ForEach(closable) { item in
                                HStack(spacing: Style.Space.xs) {
                                    if let info = model.workspace.info(item.id) { FlavorGlyph(info.flavor) }
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(model.workspace.info(item.id)?.title ?? item.id).font(Style.caption).foregroundStyle(Style.ink).lineLimit(1)
                                        Text(item.why).font(Style.caption).foregroundStyle(Style.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Button { model.workspace.steward.record("kept", tile: item.id, why: item.why) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).foregroundStyle(Style.muted).help("Keep it; don't suggest it again")
                                    Button {
                                        guard canClose(item.id) else { return }
                                        model.workspace.steward.record("closed", tile: item.id, why: item.why)
                                        model.close(item.id)
                                    } label: { Image(systemName: "archivebox") }
                                        .buttonStyle(.plain).foregroundStyle(Style.dim).help("Close or hide it")
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(item.id) }
                            }
                        }
                        .padding(.horizontal, Style.Space.s)
                    }
                }
            }
        }
    }

    private func canClose(_ id: String) -> Bool {
        guard let tile = model.workspace.info(id) else { return false }
        return Steward.canSuggestClosing(tile)
    }
}
