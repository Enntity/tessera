import SwiftUI

/// A full, readable conversation transcript (the opened state of a desktop-app session tile).
public struct Tag: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text).font(Style.mono(10, .medium)).foregroundStyle(Style.dim)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Style.glass, in: Capsule())
    }
}

public struct ConversationDetail: View {
    @Environment(\.tesseraPrivacy) private var privacy
    let snapshot: ConversationSnapshot?
    let flavor: AgentFlavor

    public init(snapshot: ConversationSnapshot?, flavor: AgentFlavor) {
        self.snapshot = snapshot
        self.flavor = flavor
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot?.items ?? []) { item in
                        row(item).id(item.id)
                    }
                    if snapshot?.activity == .working {
                        TypingDots(color: Style.accent(flavor), size: 6, spacing: 4).id("typing")
                    }
                }
                .padding(18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(snapshot?.items.last?.id, anchor: .bottom) }
            .onChange(of: snapshot?.items.last?.id) { _, last in
                withAnimation(.spring(duration: 0.3)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text.obscured(privacy)).font(Style.ui(13)).foregroundStyle(Style.ink).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Style.accent(flavor).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            (privacy ? Text(item.text.obscured(true)) : Text(LocalizedStringKey(item.text))).font(Style.ui(13)).foregroundStyle(Style.ink.opacity(0.92)).textSelection(.enabled)
        case .tool, .toolResult:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.role == .tool ? "chevron.right.2" : (item.isError ? "exclamationmark.triangle" : "arrow.turn.down.right"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(item.isError ? Style.coral : Style.accent(flavor))
                if let name = item.toolName { Text(name).font(Style.mono(11, .semibold)).foregroundStyle(Style.dim) }
                Text(item.text.obscured(privacy)).font(Style.mono(11)).foregroundStyle(Style.faint).lineLimit(2).textSelection(.enabled)
            }
        case .thinking, .system:
            EmptyView()
        }
    }
}

