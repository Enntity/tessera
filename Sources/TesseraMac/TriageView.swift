import SwiftUI
import TesseraHost
import TesseraKit

/// ⇧⌘J: the Needs-you queue as one item at a time, cleared from the keyboard like an email triage
/// view — its question or failure in full, what the tile shows, and the keys that act on it.
/// Nothing it offers moves the keyboard into a tile; answering types into the terminal unopened.
struct TriageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy
    /// The card holds the keys; `replyFocused` is the desk question's reply field, which keeps its
    /// own typing while it has them.
    @FocusState private var focused: Bool
    @FocusState private var replyFocused: Bool
    @State private var reply = ""
    /// Where in the queue the shown item was, so when it leaves the item now in its place is next.
    @State private var index = 0

    var body: some View {
        let queue = model.workspace.state.queue
        GeometryReader { geo in
            ZStack {
                Style.scrim
                    .onTapGesture { model.closeTriage() }
                if let info = current(in: queue) {
                    card(info, position: index, total: queue.count)
                        .frame(maxHeight: geo.size.height * 0.8)
                } else {
                    caughtUp
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: queue) { _, ids in
            guard let current = model.triageId else { return }
            if let position = ids.firstIndex(of: current) {
                index = position
            } else {
                // It left the queue — answered, dismissed, finished, closed. The item now in its
                // place is next (the last when it was last).
                index = ids.triageIndex(afterLeaving: index) ?? 0
                model.triageId = index < ids.count ? ids[index] : nil
                reply = ""
            }
        }
        .onKeyPress(phases: .down) { press in
            guard !replyFocused else {
                // The reply field keeps its typing; Esc steps back out of it to the card.
                if press.key == .escape { replyFocused = false; return .handled }
                return .ignored
            }
            return key(press)
        }
    }

    /// The item triage is on: `triageId` while the queue still has it.
    private func current(in queue: [String]) -> TileInfo? {
        guard let id = model.triageId, queue.contains(id) else { return nil }
        return model.workspace.info(id)
    }

    // MARK: The card

    private func card(_ info: TileInfo, position: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(info, position: position, total: total)
            Hairline()
            // As tall as it reads: the line, the steward's take, and a scrolled box of what the
            // tile shows — so the card sits tight around the item, not stretched to the window.
            VStack(alignment: .leading, spacing: Style.Space.m) {
                // A question or failure in its own words; a result's line in its state's colour —
                // its own last line when neither the steward nor the tile said anything about it.
                let hidden = privacy && info.activity != .failed
                let line = shownLaneLine(info, model.workspace)
                Text(hidden ? line.obscured(true) : line)
                    .font(Style.body)
                    .foregroundStyle(info.activity == .needsInput ? Style.ink : Style.state(info.activity))
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = info.summary, summary != line {
                    HStack(alignment: .top, spacing: Style.Space.xs) {
                        Image(systemName: "sparkles").font(Style.caption).foregroundStyle(Style.accent(.agentDesk))
                        Text(summary.obscured(hidden)).font(Style.caption).foregroundStyle(Style.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let text = model.workspace.shownText(info.id, lines: 18), !text.isEmpty {
                    let content = Text(privacy ? text.obscured(true) : text)
                        .font(Style.mono(.caption))
                        .foregroundStyle(Style.dim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // As tall as the tile's tail when it fits; scrolled past that.
                    ViewThatFits(in: .vertical) {
                        content
                        ScrollView { content }.frame(maxHeight: 280)
                    }
                    .padding(Style.Space.m)
                    .background(Style.terminalBackground, in: Style.shape(Style.Radius.m))
                    .overlay(Style.shape(Style.Radius.m).strokeBorder(Style.hairline))
                }
            }
            .padding(Style.Space.xl)
            Hairline()
            actions(info)
            KeyHints(hints: hints(for: info))
        }
        .frame(width: 760)
        .overlaySurface()
    }

    private func header(_ info: TileInfo, position: Int, total: Int) -> some View {
        HStack(spacing: Style.Space.s) {
            FlavorGlyph(info.flavor)
            Text(info.title).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
            Text(info.subtitle.abbreviatingHome).font(Style.caption).foregroundStyle(Style.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: Style.Space.s)
            Text(info.activity == .done ? "To review" : info.activity.label)
                .font(Style.ui(.caption, .semibold))
                .foregroundStyle(Style.state(info.activity))
                .padding(.horizontal, Style.Space.s)
                .frame(height: Style.Metrics.key)
                .background(Style.state(info.activity).opacity(Style.Tint.fill), in: Style.shape(Style.Radius.xs))
            Age(of: info.lastActivityAt).font(Style.caption).foregroundStyle(Style.muted)
            Text("\(position + 1) of \(total)").font(Style.caption).foregroundStyle(Style.muted)
            Button { model.closeTriage() } label: {
                Image(systemName: "xmark")
                    .font(Style.ui(.caption, .bold))
                    .frame(width: Style.Metrics.key, height: Style.Metrics.key)
                    .foregroundStyle(Style.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close triage (esc)")
        }
        .padding(.horizontal, Style.Space.xl)
        .padding(.vertical, Style.Space.m)
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ info: TileInfo) -> some View {
        let desk = model.workspace.desk
        HStack(spacing: Style.Space.s) {
            if info.activity == .needsInput, info.kind == .terminal {
                QuickAnswers(id: info.id)
            } else if info.activity == .needsInput, info.flavor == .agentDesk, let options = desk.choices(for: info.id) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    keyButton("\(i + 1) \(option)", key: "\(i + 1)", color: Style.amber) {
                        desk.respond(info.id, with: option)
                    }
                }
                if options != ["Deliver", "Don't"] {
                    TextField("Reply…", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .font(Style.caption)
                        .frame(maxWidth: 200)
                        .focused($replyFocused)
                        .onSubmit {
                            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            desk.respond(info.id, with: text)
                            reply = ""
                        }
                }
            } else {
                if info.activity == .failed, let action = model.actions(for: info).first {
                    keyButton(action.title, key: "R", color: Style.coral) { action.run() }
                }
                keyButton(info.activity == .needsInput ? "Dismiss" : "Mark as Seen", key: "E") { model.workspace.dismiss(info.id) }
            }
            Spacer(minLength: Style.Space.s)
            keyButton("Back", key: "←") { move(-1) }
            keyButton("Open", key: "O") { model.open(info.id) }
            keyButton("Skip", key: "→") { move(1) }
        }
        .padding(.horizontal, Style.Space.xl)
        .padding(.vertical, Style.Space.m)
    }

    /// A button big enough to click that still names its key.
    private func keyButton(_ title: String, key: String, color: Color = Style.ink, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: Style.Space.xs) {
                Text(title).font(Style.ui(.label, .semibold))
                Text(key).font(Style.caption).foregroundStyle(Style.muted)
            }
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Style.Space.m)
            .frame(height: Style.Metrics.control)
            .background(color.opacity(Style.Tint.fill), in: Style.shape(Style.Radius.s))
            .overlay(Style.shape(Style.Radius.s).strokeBorder(Style.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The keys valid for this item, for the strip along the card's bottom.
    private func hints(for info: TileInfo) -> [KeyHint] {
        var first: [KeyHint] = []
        if info.activity == .needsInput, info.kind == .terminal {
            first = [KeyHint("1–3 y n ⏎", "answer"), KeyHint("E", "set aside")]
        } else if info.activity == .needsInput, let options = model.workspace.desk.choices(for: info.id) {
            first = [KeyHint("1–\(options.count)", "answer")]
            if options != ["Deliver", "Don't"] { first.append(KeyHint("⇥", "reply")) }
            first.append(KeyHint("E", "set aside"))
        } else {
            if info.activity == .failed, let action = model.actions(for: info).first {
                first.append(KeyHint("R", action.title.lowercased()))
            }
            first.append(KeyHint("E", info.activity == .needsInput ? "set aside" : "seen"))
        }
        return first + [KeyHint("O", "open"), KeyHint("← →", "back · skip"), KeyHint("esc", "close")]
    }

    private var caughtUp: some View {
        VStack(spacing: Style.Space.m) {
            Image(systemName: "checkmark.circle").font(Style.title).foregroundStyle(Style.faint)
            Text("All caught up").font(Style.ui(.body, .medium)).foregroundStyle(Style.muted)
            Text("esc to close").font(Style.caption).foregroundStyle(Style.faint)
        }
        .padding(Style.Space.xxl * 2)
        .overlaySurface()
        .task {
            // Nothing left: a beat to read it, then the board again.
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled, await MainActor.run(body: { model.workspace.state.queue.isEmpty }) { model.closeTriage() }
        }
    }

    // MARK: Keys

    private func move(_ step: Int) {
        let queue = model.workspace.state.queue
        guard !queue.isEmpty else { return }
        index = queue.triageIndex(from: index, by: step)
        model.triageId = queue[index]
    }

    /// A key while the card has them. A focused reply field got waved off before this is called.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape: model.closeTriage(); return .handled
        case .leftArrow: move(-1); return .handled
        case .rightArrow: move(1); return .handled
        case .return:
            guard let info = current(in: model.workspace.state.queue) else { model.closeTriage(); return .handled }
            if info.activity == .needsInput, info.kind == .terminal { model.answer(info.id, with: .enter) } else { model.open(info.id) }
            return .handled
        case .tab:
            // The desk question's reply field takes the keyboard.
            guard let info = current(in: model.workspace.state.queue), info.flavor == .agentDesk,
                  let options = model.workspace.desk.choices(for: info.id), options != ["Deliver", "Don't"] else { return .ignored }
            replyFocused = true
            return .handled
        default: break
        }
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
              let info = current(in: model.workspace.state.queue) else { return .ignored }
        switch press.characters.lowercased() {
        case "e": model.workspace.dismiss(info.id); return .handled
        case "r":
            guard info.activity == .failed, let action = model.actions(for: info).first else { return .ignored }
            action.run()
            return .handled
        case "o": model.open(info.id); return .handled
        case "j": move(1); return .handled
        case "k": move(-1); return .handled
        case let keys where info.activity == .needsInput && info.kind == .terminal:
            guard let answer = QuickAnswer(rawValue: keys) else { return .ignored }
            model.answer(info.id, with: answer)
            return .handled
        case let keys where info.activity == .needsInput:
            // A desk question's options, numbered.
            guard let digit = keys.first.flatMap({ Int(String($0)) }), digit >= 1,
                  let options = model.workspace.desk.choices(for: info.id), digit <= options.count else { return .ignored }
            model.workspace.desk.respond(info.id, with: options[digit - 1])
            return .handled
        default: return .ignored
        }
    }
}
