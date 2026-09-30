import SwiftUI

/// A full, readable conversation transcript (the opened state of a desktop-app session tile).
public struct ConversationDetail: View {
    @Environment(\.tesseraPrivacy) private var privacy
    let snapshot: ConversationSnapshot?

    public init(snapshot: ConversationSnapshot?) { self.snapshot = snapshot }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Style.Space.gutter) {
                    ForEach(snapshot?.items ?? []) { item in
                        row(item).id(item.id)
                    }
                    if snapshot?.activity == .working {
                        TypingDots(color: Style.cyan, size: 6, spacing: 4).id("typing")
                    }
                }
                .padding(Style.Space.l)
                .frame(maxWidth: Style.Metrics.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(snapshot?.items.last?.id, anchor: .bottom) }
            .onChange(of: snapshot?.items.last?.id) { _, last in
                withAnimation(Style.Motion.standard) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text.obscured(privacy)).font(Style.body).foregroundStyle(Style.ink).textSelection(.enabled)
                    .padding(.horizontal, Style.Space.l).padding(.vertical, Style.Space.m)
                    .background(Style.Neutral.selected, in: Style.shape(Style.Radius.m))
            }
        case .assistant:
            (privacy ? Text(item.text.obscured(true)) : Text(LocalizedStringKey(item.text))).font(Style.body).foregroundStyle(Style.ink).textSelection(.enabled)
        case .tool, .toolResult:
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Image(systemName: item.role == .tool ? "chevron.right.2" : (item.isError ? "exclamationmark.triangle" : "arrow.turn.down.right"))
                    .font(Style.ui(.caption, .bold))
                    .foregroundStyle(item.isError ? Style.coral : Style.muted)
                if let name = item.toolName { Text(name).font(Style.mono(.label, .semibold)).foregroundStyle(Style.dim) }
                Text(item.text.obscured(privacy)).font(Style.mono(.label)).foregroundStyle(Style.muted).lineLimit(2).textSelection(.enabled)
            }
        case .thinking, .system:
            EmptyView()
        }
    }
}

