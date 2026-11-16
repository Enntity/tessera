import SwiftUI

/// What an assistant message's text is made of, rendered block by block: an ordinary paragraph,
/// a bullet or numbered row, a heading, or a fenced run of code shown verbatim.
public enum ConversationBlock: Hashable, Sendable {
    case paragraph(String)
    case bullet(String)
    case number(Int, String)
    case heading(Int, String)
    case code(String)
}

enum ConversationBlocks {
    /// Splits `text` on blank lines into paragraphs; within one, `- `/`* ` lines become bullets,
    /// `1. ` lines numbered rows, `#`–`###` lines headings, and ``` fences literal code.
    static func split(_ text: String) -> [ConversationBlock] {
        var blocks: [ConversationBlock] = []
        var paragraph: [String] = []
        var fence: [String]?
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = fence {
                    fence = nil
                    blocks.append(.code(open.joined(separator: "\n")))
                } else {
                    flush()
                    fence = []
                }
                continue
            }
            if fence != nil { fence!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            var level = 0
            for prefix in ["### ", "## ", "# "] {
                if line.hasPrefix(prefix) { level = prefix.count - 1; break }
            }
            if level > 0 {
                flush()
                blocks.append(.heading(level, String(line.dropFirst(level + 1))))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            let digits = line.prefix(while: \.isNumber)
            if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
                flush()
                blocks.append(.number(Int(digits)!, String(line.dropFirst(digits.count + 2))))
                continue
            }
            paragraph.append(line)
        }
        flush()
        if let open = fence { blocks.append(.code(open.joined(separator: "\n"))) }
        return blocks
    }
}

/// A full, readable conversation transcript (the opened state of a desktop-app session tile).
public struct ConversationDetail: View {
    @Environment(\.tesseraPrivacy) private var privacy
    let snapshot: ConversationSnapshot?
    /// Runs of tool calls and their results fold into one muted row that opens on a click
    /// (used where the conversation itself is the point, like the overseer's panel).
    var collapseTools = false
    @State private var expanded: Set<String> = []

    public init(snapshot: ConversationSnapshot?, collapseTools: Bool = false) {
        self.snapshot = snapshot
        self.collapseTools = collapseTools
    }

    /// What the list shows: items, with tool runs folded when `collapseTools`.
    private enum Row: Identifiable {
        case item(ConversationItem)
        case tools(String, [ConversationItem])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .tools(let id, _): id
            }
        }
    }

    private var rows: [Row] {
        let items = snapshot?.items ?? []
        guard collapseTools else { return items.map(Row.item) }
        var rows: [Row] = []
        var run: [ConversationItem] = []
        for item in items {
            if [.tool, .toolResult].contains(item.role) {
                run.append(item)
            } else {
                if !run.isEmpty { rows.append(.tools(run[0].id, run)); run = [] }
                rows.append(.item(item))
            }
        }
        if !run.isEmpty { rows.append(.tools(run[0].id, run)) }
        return rows
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Style.Space.gutter) {
                    ForEach(rows) { line in
                        switch line {
                        case .item(let item): row(item).id(item.id)
                        case .tools(let id, let items): toolRun(id: id, items: items)
                        }
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

    /// A folded run of tool calls: "N steps · " and the tools used, opened to the full lines.
    @ViewBuilder
    private func toolRun(id: String, items: [ConversationItem]) -> some View {
        var seen = Set<String>()
        let names = items.compactMap(\.toolName).map(Self.shortTool).filter { seen.insert($0).inserted }
        Button {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                Image(systemName: "gearshape")
                    .font(Style.ui(.caption, .bold))
                    .foregroundStyle(items.contains(where: \.isError) ? Style.coral : Style.muted)
                Text("\(items.count) step\(items.count == 1 ? "" : "s")\(names.isEmpty ? "" : " · " + names.joined(separator: ", "))")
                    .font(Style.mono(.label)).foregroundStyle(Style.muted)
                Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right")
                    .font(Style.ui(.micro)).foregroundStyle(Style.muted)
            }
        }
        .buttonStyle(.plain)
        .id(id)
        if expanded.contains(id) {
            ForEach(items) { item in row(item) }
        }
    }

    /// `mcp__tessera__board` → `board`: a tool name to what the user calls it.
    static func shortTool(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let rest = name.dropFirst(5)
        guard let sep = rest.range(of: "__") else { return name }
        return String(rest[sep.upperBound...])
    }

    /// One assistant line: inline markdown, or the block's own shape for bullets, rows,
    /// headings and code.
    @ViewBuilder
    private func inline(_ text: String) -> some View {
        (privacy ? Text(text.obscured(true)) : Text(LocalizedStringKey(text))).textSelection(.enabled)
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
            ForEach(ConversationBlocks.split(item.text), id: \.self) { block in
                switch block {
                case .paragraph(let text):
                    inline(text).font(Style.body).foregroundStyle(Style.ink)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: Style.Space.s) {
                        Text("•").foregroundStyle(Style.muted)
                        inline(text).font(Style.body).foregroundStyle(Style.ink)
                    }
                    .padding(.leading, Style.Space.m)
                case .number(let n, let text):
                    HStack(alignment: .top, spacing: Style.Space.s) {
                        Text("\(n).").foregroundStyle(Style.muted)
                        inline(text).font(Style.body).foregroundStyle(Style.ink)
                    }
                    .padding(.leading, Style.Space.m)
                case .heading(_, let text):
                    inline(text).font(Style.ui(.body, .semibold)).foregroundStyle(Style.ink)
                case .code(let text):
                    inline(text).font(Style.mono(.label)).foregroundStyle(Style.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Style.Space.m)
                        .background(Style.Neutral.hover, in: Style.shape(Style.Radius.s))
                }
            }
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
