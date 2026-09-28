import SwiftTerm
import SwiftUI

/// Live terminal screen drawn with `MiniTerminalRenderer`. Redraws only when `revision` changes.
public struct TerminalThumbnail: View, Equatable {
    let terminal: Terminal
    let revision: Int
    var showCursor: Bool

    public init(terminal: Terminal, revision: Int, showCursor: Bool = true) {
        self.terminal = terminal
        self.revision = revision
        self.showCursor = showCursor
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.terminal === b.terminal && a.revision == b.revision && a.showCursor == b.showCursor
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            ctx.withCGContext { cg in
                SharedRenderer.instance.draw(terminal, in: cg, size: size, showCursor: showCursor)
            }
        }
        .background(Style.terminalBackground)
    }
}

@MainActor
enum SharedRenderer {
    static let instance = MiniTerminalRenderer()
}

/// A desktop-app conversation as a living card: latest exchange, tool activity, and a typing
/// indicator while the agent works.
public struct ConversationThumbnail: View {
    let snapshot: ConversationSnapshot?
    let flavor: AgentFlavor
    var maxItems: Int
    var fontScale: CGFloat

    public init(snapshot: ConversationSnapshot?, flavor: AgentFlavor, maxItems: Int = 7, fontScale: CGFloat = 1) {
        self.snapshot = snapshot
        self.flavor = flavor
        self.maxItems = maxItems
        self.fontScale = fontScale
    }

    public var body: some View {
        let items = Array((snapshot?.items ?? []).filter { $0.role != .toolResult || $0.isError }.suffix(maxItems))
        VStack(alignment: .leading, spacing: 4 * fontScale) {
            Spacer(minLength: 0)
            ForEach(items) { item in
                row(item)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            if snapshot?.activity == .working {
                TypingDots(color: Style.accent(flavor)).padding(.leading, 2)
            }
        }
        .animation(.spring(duration: 0.35), value: items.last?.id)
        .padding(8 * fontScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .background(
            LinearGradient(colors: [Style.accent(flavor).opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 24 * fontScale)
                Text(item.text.preview(220))
                    .font(Style.ui(10 * fontScale))
                    .foregroundStyle(Style.ink)
                    .lineLimit(3)
                    .padding(.horizontal, 7 * fontScale)
                    .padding(.vertical, 4 * fontScale)
                    .background(Style.accent(flavor).opacity(0.18), in: RoundedRectangle(cornerRadius: 7 * fontScale, style: .continuous))
            }
        case .assistant:
            Text(item.text.preview(400))
                .font(Style.ui(10 * fontScale))
                .foregroundStyle(Style.ink.opacity(0.9))
                .lineLimit(4)
        case .tool, .toolResult:
            HStack(spacing: 4 * fontScale) {
                Image(systemName: item.isError ? "exclamationmark.triangle.fill" : "chevron.right.2")
                    .font(.system(size: 7 * fontScale, weight: .bold))
                    .foregroundStyle(item.isError ? Style.coral : Style.accent(flavor))
                Text(item.toolName ?? "tool")
                    .font(Style.mono(8.5 * fontScale, .semibold))
                    .foregroundStyle(Style.dim)
                Text(item.text)
                    .font(Style.mono(8.5 * fontScale))
                    .foregroundStyle(Style.faint)
                    .lineLimit(1)
            }
        case .thinking, .system:
            EmptyView()
        }
    }
}

struct TypingDots: View {
    let color: SwiftUI.Color
    @State private var on = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(color).frame(width: 4, height: 4)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}

/// A ring showing how much is left, colored by urgency.
public struct UsageRing: View {
    let remaining: Double?
    var size: CGFloat

    public init(remaining: Double?, size: CGFloat = 30) {
        self.remaining = remaining
        self.size = size
    }

    public var body: some View {
        let value = remaining ?? 0
        let color = remaining == nil ? Style.faint : (value > 0.4 ? Style.mint : value > 0.15 ? Style.amber : Style.coral)
        ZStack {
            Circle().stroke(Style.hairline, lineWidth: 3)
            if remaining != nil {
                Circle().trim(from: 0, to: value)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 3)
                Text("\(Int((value * 100).rounded()))")
                    .font(Style.mono(size * 0.3, .semibold))
                    .foregroundStyle(color)
            } else {
                Image(systemName: "infinity").font(.system(size: size * 0.3)).foregroundStyle(Style.faint)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.6), value: value)
    }
}

/// One provider in the usage panel.
public struct UsageRow: View {
    let reading: UsageReading
    var onTopUp: ((URL) -> Void)?

    public init(reading: UsageReading, onTopUp: ((URL) -> Void)? = nil) {
        self.reading = reading
        self.onTopUp = onTopUp
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UsageRing(remaining: reading.remaining)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: reading.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Style.dim)
                    Text(reading.name).font(Style.ui(11, .semibold)).foregroundStyle(Style.ink).lineLimit(1)
                }
                switch reading.status {
                case .loading:
                    Text("Checking…").font(Style.mono(10)).foregroundStyle(Style.faint)
                case .needsKey:
                    Text("Add a key in Settings").font(Style.mono(10)).foregroundStyle(Style.faint)
                case .error:
                    Text(reading.headline.isEmpty ? "Unavailable" : reading.headline).font(Style.mono(11, .semibold)).foregroundStyle(Style.coral)
                    if let m = reading.message { Text(m).font(Style.mono(9)).foregroundStyle(Style.faint).lineLimit(2) }
                case .ok:
                    Text(reading.headline).font(Style.mono(12, .semibold)).foregroundStyle(Style.ink)
                    ForEach(reading.lines, id: \.self) { line in
                        Text(line).font(Style.mono(9)).foregroundStyle(Style.dim).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let s = reading.topUpURL, let url = URL(string: s) {
                Button {
                    onTopUp?(url)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Style.cyan)
                }
                .buttonStyle(.plain)
                .help("Top up / manage billing")
            }
        }
        .padding(10)
        .background(Style.glass.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Style.hairline))
    }
}
