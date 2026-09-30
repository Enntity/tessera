import SwiftTerm
import SwiftUI

/// Live terminal screen drawn with `MiniTerminalRenderer`. Redraws only when `revision` changes.
public struct TerminalThumbnail: View, Equatable {
    let terminal: Terminal
    let revision: Int
    var showCursor: Bool
    var obscured: Bool

    public init(terminal: Terminal, revision: Int, showCursor: Bool = true, obscured: Bool = false) {
        self.terminal = terminal
        self.revision = revision
        self.showCursor = showCursor
        self.obscured = obscured
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.terminal === b.terminal && a.revision == b.revision && a.showCursor == b.showCursor && a.obscured == b.obscured
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            ctx.withCGContext { cg in
                SharedRenderer.instance.draw(terminal, in: cg, size: size, showCursor: showCursor, obscured: obscured)
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
    @Environment(\.tesseraPrivacy) private var privacy
    let snapshot: ConversationSnapshot?
    let flavor: AgentFlavor
    var maxItems: Int
    var fontScale: CGFloat

    /// The scale at which conversation text reads the same size as terminal tile text.
    public static let terminalMatchedScale: CGFloat = 0.65

    public init(snapshot: ConversationSnapshot?, flavor: AgentFlavor, maxItems: Int = 7, fontScale: CGFloat = 1) {
        self.snapshot = snapshot
        self.flavor = flavor
        self.maxItems = maxItems
        self.fontScale = fontScale
    }

    public var body: some View {
        let items = Array((snapshot?.items ?? []).filter { $0.role != .toolResult || $0.isError }.suffix(maxItems))
        // Takes the room it is given and no more: the newest lines sit at the bottom, and older
        // ones fade out under the header.
        Color.clear
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Style.Space.xs * fontScale) {
                    ForEach(items) { item in
                        row(item)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if snapshot?.activity == .working {
                        TypingDots(color: Style.cyan).padding(.leading, Style.Space.xxs)
                    }
                }
                .animation(Style.Motion.standard, value: items.last?.id)
                .padding(.horizontal, Style.Space.m)
                .padding(.vertical, Style.Space.s)
            }
            .clipped()
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Style.Space.xl)
                    Color.black
                }
            }
            .background(
                LinearGradient(colors: [Style.accent(flavor).opacity(Style.Tint.wash), .clear], startPoint: .top, endPoint: .bottom)
            )
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 24 * fontScale)
                Text(privacy ? AttributedString(item.text.preview(220).obscured(true)) : item.text.markdownPreview(220))
                    .font(Style.ui(10 * fontScale))
                    .foregroundStyle(Style.ink)
                    .lineLimit(3)
                    .padding(.horizontal, Style.Space.s * fontScale)
                    .padding(.vertical, Style.Space.xs * fontScale)
                    .background(Style.Neutral.selected, in: Style.shape(Style.Radius.xs))
            }
        case .assistant:
            Text(privacy ? AttributedString(item.text.preview(400).obscured(true)) : item.text.markdownPreview(400))
                .font(Style.ui(10 * fontScale))
                .foregroundStyle(Style.ink.opacity(0.9))
                .lineLimit(4)
        case .tool, .toolResult:
            HStack(spacing: 4 * fontScale) {
                Image(systemName: item.isError ? "exclamationmark.triangle.fill" : "chevron.right.2")
                    .font(.system(size: 7 * fontScale, weight: .bold))
                    .foregroundStyle(item.isError ? Style.coral : Style.muted)
                Text(item.toolName ?? "tool")
                    .font(Style.mono(9.6 * fontScale, .semibold))
                    .foregroundStyle(Style.dim)
                Text(item.text.obscured(privacy))
                    .font(Style.mono(9.6 * fontScale))
                    .foregroundStyle(Style.muted)
                    .lineLimit(1)
            }
        case .thinking, .system:
            EmptyView()
        }
    }
}

/// A gauge of how much is left around the provider's glyph: quiet while there is plenty, amber
/// when it runs low, coral when it is nearly gone.
public struct UsageRing: View {
    let remaining: Double?
    let symbol: String
    var size: CGFloat

    public init(remaining: Double?, symbol: String, size: CGFloat = 30) {
        self.remaining = remaining
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        let value = remaining ?? 0
        let color = value > 0.4 ? Style.dim : value > 0.15 ? Style.amber : Style.coral
        ZStack {
            Circle().stroke(Style.hairline, lineWidth: 3)
            if remaining != nil {
                Circle().trim(from: 0, to: value)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol).font(Style.ui(.caption, .semibold)).foregroundStyle(Style.dim)
        }
        .frame(width: size, height: size)
        .animation(Style.Motion.data, value: value)
    }
}

/// One provider in the usage panel: its gauge, its name, the one number that matters, then the
/// details.
public struct UsageRow: View {
    let reading: UsageReading
    var onTopUp: ((URL) -> Void)?

    public init(reading: UsageReading, onTopUp: ((URL) -> Void)? = nil) {
        self.reading = reading
        self.onTopUp = onTopUp
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Style.Space.gutter) {
            UsageRing(remaining: reading.remaining, symbol: reading.symbol)
            VStack(alignment: .leading, spacing: Style.Space.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.name).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if let s = reading.topUpURL, let url = URL(string: s) {
                        Button {
                            onTopUp?(url)
                        } label: {
                            Image(systemName: "plus.circle").font(Style.label).foregroundStyle(Style.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Top up / manage billing")
                    }
                }
                switch reading.status {
                case .loading:
                    Text("Checking…").foregroundStyle(Style.muted)
                case .needsKey:
                    Text("Add a key in Settings").foregroundStyle(Style.muted)
                case .error:
                    Text(reading.headline.isEmpty ? "Unavailable" : reading.headline).font(Style.mono(.label, .semibold)).foregroundStyle(Style.coral)
                    if let m = reading.message { Text(m).foregroundStyle(Style.muted).lineLimit(2) }
                case .ok:
                    Text(reading.headline).font(Style.mono(.body, .semibold)).foregroundStyle(Style.ink)
                    ForEach(reading.lines, id: \.self) { line in
                        Text(line).foregroundStyle(Style.dim).lineLimit(1)
                    }
                    if let note = reading.message {
                        Text(note).foregroundStyle(Style.muted).lineLimit(2)
                    }
                }
            }
            .font(Style.caption)
        }
        .padding(Style.Space.gutter)
        .cardSurface()
    }
}
