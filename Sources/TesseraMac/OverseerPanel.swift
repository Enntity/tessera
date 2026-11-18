import SwiftUI
import TesseraHost
import TesseraKit

/// ⌘O: the overseer's panel — Tessera's voice on the board. Its conversation as a chat when the
/// agent keeps a transcript (or its empty state with things to ask), its terminal when there is
/// no transcript or while it is asking something only the terminal can answer, and a composer
/// that puts a question to it. It floats under the top bar at the lane's edge, and Esc or the
/// scrim puts it away.
struct OverseerPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tesseraPrivacy) private var privacy
    /// What the user picked; `asking` overrides it to the terminal until the prompt is answered.
    @State private var mode = Mode.chat
    @State private var draft = ""
    /// The brief the user collapsed, by when it was written — a newer brief opens again.
    @State private var collapsedBriefAt: Date?
    @FocusState private var composerFocused: Bool

    private enum Mode { case chat, terminal }

    var body: some View {
        let workspace = model.workspace
        let tile = workspace.overseerId.flatMap(workspace.info)
        let working = tile?.activity == .working
        let asking = tile?.activity == .needsInput
        let chat = workspace.overseerChat
        let terminal = workspace.overseerId.flatMap { workspace.terminals[$0] }
        let shown: Mode = asking || !chat.hasTranscript ? .terminal : mode
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    header(tile: tile, shown: shown)
                        .padding(Style.Space.l)
                    Hairline()
                    if asking {
                        HStack(spacing: Style.Space.s) {
                            Image(systemName: "questionmark.circle").foregroundStyle(Style.state(.needsInput))
                            Text("Tessera is asking in its terminal. Answer below.").font(Style.caption).foregroundStyle(Style.dim)
                            Spacer()
                        }
                        .padding(.horizontal, Style.Space.l)
                        .padding(.vertical, Style.Space.s)
                        .background(Style.state(.needsInput).opacity(0.08))
                        Hairline()
                    }
                    briefBlock(maxHeight: min(780, geo.size.height - 2 * Style.Space.xl) * 0.4)
                    switch shown {
                    case .chat: chatBody
                    case .terminal:
                        if let terminal {
                            ReparentHost(view: terminal.view, focus: true)
                                .padding(.horizontal, Style.Space.m)
                                .padding(.vertical, Style.Space.s)
                                .background(Style.terminalBackground)
                        } else {
                            missing
                        }
                    }
                }
                .overlaySurface()
                .auroraBorder(active: working, radius: Style.Radius.l)
                .clipShape(RoundedRectangle(cornerRadius: Style.Radius.l, style: .continuous))
                .padding(.leading, model.showLane ? Style.Space.l : Style.Space.xl)
                .padding(.top, Style.Metrics.hud + Style.Space.s)
                .frame(width: min(620, geo.size.width - 2 * Style.Space.xl),
                       height: min(780, geo.size.height - 2 * Style.Space.xl),
                       alignment: .topLeading)
            }
        }
        .onKeyPress(phases: .down) { press in
            // Esc puts the chat away; in the terminal it belongs to the terminal (⌘O or ✕ close).
            guard shown == .chat, press.key == .escape else { return .ignored }
            model.closeOverseer()
            return .handled
        }
        .onAppear { if shown == .chat { composerFocused = true } }
    }

    @ViewBuilder
    private func header(tile: TileInfo?, shown: Mode) -> some View {
        HStack(spacing: Style.Space.m) {
            OverseerOrb(size: 28, active: tile?.activity == .working)
            VStack(alignment: .leading, spacing: Style.Space.xxs) {
                Text("Tessera").font(Style.ui(.title, .semibold)).foregroundStyle(Style.ink)
                Text(status(tile)).font(Style.caption).foregroundStyle(Style.dim)
            }
            Spacer()
            if model.workspace.overseerChat.hasTranscript {
                modePicker(shown: shown)
            }
            Button {
                let folder = model.workspace.overseerDirectory
                try? Overseer.prepare(folder)
                NSWorkspace.shared.activateFileViewerSelecting([Overseer.roleFile(in: folder)])
            } label: { Image(systemName: "doc.text") }
                .buttonStyle(.plain).foregroundStyle(Style.muted)
                .help("Open the overseer's role (AGENTS.md)")
            Button { model.closeOverseer() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Style.muted)
                .help(shown == .chat ? "Close (esc)" : "Close (⌘O)")
        }
    }

    /// "Looking into it…" · "Waiting for your answer" · "Ready" · "Starting…".
    private func status(_ tile: TileInfo?) -> String {
        switch tile?.activity {
        case .working: return "Looking into it…"
        case .needsInput: return "Waiting for your answer"
        case nil, .starting: return "Starting…"
        default: return "Ready"
        }
    }

    @ViewBuilder
    private func modePicker(shown: Mode) -> some View {
        HStack(spacing: 0) {
            pick("Chat", on: shown == .chat) { mode = .chat }
            pick("Terminal", on: shown == .terminal) { mode = .terminal }
        }
        .overlay(Capsule().strokeBorder(Style.Neutral.border))
    }

    private func pick(_ label: String, on: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            Text(label).font(Style.caption)
                .foregroundStyle(on ? Style.ink : Style.muted)
                .padding(.horizontal, Style.Space.m)
                .padding(.vertical, Style.Space.xs)
        }
        .buttonStyle(.plain)
    }

    /// The conversation, or what to ask it first when there is nothing yet.
    @ViewBuilder private var chatBody: some View {
        let chat = model.workspace.overseerChat
        if let items = chat.snapshot?.items, !items.isEmpty {
            ConversationDetail(snapshot: chat.snapshot, collapseTools: true)
        } else {
            VStack(spacing: Style.Space.l) {
                Spacer()
                OverseerOrb(size: 64, active: false)
                Text("Ask me anything about the board").font(Style.ui(.label, .medium)).foregroundStyle(Style.ink)
                VStack(alignment: .leading, spacing: Style.Space.s) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button { model.openOverseer(asking: s) } label: {
                            Text(s).font(Style.caption).foregroundStyle(Style.dim)
                                .padding(.horizontal, Style.Space.m).padding(.vertical, Style.Space.xs)
                                .overlay(Capsule().strokeBorder(Style.Neutral.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        composer
    }

    /// The steward's board brief, pinned above the chat or the terminal alike: what the lane's
    /// card quotes when there is no unseen reply. Collapses to its header until the next brief lands, and caps its
    /// height so a long brief doesn't push the chat away. Plain text only — the model read
    /// untrusted screens, so nothing it writes becomes a link.
    @ViewBuilder private func briefBlock(maxHeight: CGFloat) -> some View {
        let steward = model.workspace.steward
        if steward.config.enabled, let brief = steward.brief, !brief.headline.isEmpty {
            let collapsed = collapsedBriefAt == brief.at
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    collapsedBriefAt = collapsed ? nil : brief.at
                } label: {
                    HStack(spacing: Style.Space.s) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(Style.caption).foregroundStyle(Style.Overseer.violet)
                        Text("Board brief").micro().foregroundStyle(Style.muted)
                        Age(of: brief.at).font(Style.caption).foregroundStyle(Style.muted)
                        if collapsed {
                            Text(brief.headline.obscured(privacy))
                                .font(Style.caption).foregroundStyle(Style.dim).lineLimit(1)
                                .layoutPriority(-1)
                        }
                        Spacer()
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(Style.caption).foregroundStyle(Style.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed {
                    // Hugs the content; the scrollable branch only wins when the brief is taller
                    // than the room left, and is itself capped.
                    ViewThatFits(in: .vertical) {
                        briefDetail(brief)
                        ScrollView { briefDetail(brief) }.frame(maxHeight: maxHeight)
                    }
                    .padding(.top, Style.Space.s)
                }
            }
            .padding(Style.Space.m)
            .background {
                Style.Overseer.violet.opacity(0.07)
                    .clipShape(RoundedRectangle(cornerRadius: Style.Radius.m, style: .continuous))
            }
            .padding(.horizontal, Style.Space.l)
            .padding(.top, Style.Space.m)
        }
    }

    /// The expanded brief body: full headline, attention rows, changes, and the follow-up question.
    @ViewBuilder private func briefDetail(_ brief: Steward.Brief) -> some View {
        VStack(alignment: .leading, spacing: Style.Space.m) {
            Text(brief.headline.obscured(privacy))
                .font(Style.caption).foregroundStyle(Style.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !brief.attention.isEmpty {
                VStack(alignment: .leading, spacing: Style.Space.xs) {
                    ForEach(brief.attention) { item in
                        Button {
                            model.closeOverseer()
                            model.open(item.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(Style.caption).foregroundStyle(Style.state(.needsInput))
                                Text((model.workspace.info(item.id)?.title ?? item.id).obscured(privacy))
                                    .font(Style.caption).foregroundStyle(Style.ink)
                                Text(item.why.obscured(privacy))
                                    .font(Style.caption).foregroundStyle(Style.dim)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !brief.changes.isEmpty {
                VStack(alignment: .leading, spacing: Style.Space.xxs) {
                    ForEach(brief.changes, id: \.self) { change in
                        Text("· " + change.obscured(privacy))
                            .font(Style.caption).foregroundStyle(Style.dim)
                    }
                }
            }
            Button {
                model.openOverseer(asking: "About the board brief: \"\(brief.headline)\" — tell me more and what I should do.")
            } label: {
                Text("Ask Tessera about this").font(Style.caption).foregroundStyle(Style.dim)
                    .padding(.horizontal, Style.Space.m).padding(.vertical, Style.Space.xs)
                    .overlay(Capsule().strokeBorder(Style.Neutral.border))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let suggestions = [
        "What needs me right now?",
        "What's stuck, and why?",
        "Who's using the Sparks?",
        "Catch me up on the last few hours",
    ]

    /// The question, pinned to the bottom: ⏎ sends, ⇧⏎ a newline.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: Style.Space.s) {
            TextField("Ask about the board, or tell Tessera what to get the agents doing…",
                      text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(Style.body)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit { send() }
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Style.title)
                    .foregroundStyle(Style.Overseer.violet)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Style.Space.l)
        .overlay(alignment: .top) { Hairline() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.openOverseer(asking: text)
    }

    /// The overseer's tile is gone or hasn't started — it is started on open, so this is the
    /// brief moment in between, or a failed launch.
    private var missing: some View {
        VStack(spacing: Style.Space.m) {
            Spacer()
            OverseerOrb(size: 64, active: false)
            Text("Starting…").font(Style.ui(.label, .medium)).foregroundStyle(Style.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
