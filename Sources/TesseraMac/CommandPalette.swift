import SwiftUI
import TesseraHost
import TesseraKit

/// ⌘K: launch any agent, run any command, open any URL, or jump to any tile — one field.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let subtitle: String
        let run: () -> Void
    }

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: model.paletteMode == .url ? "globe" : "command").foregroundStyle(Style.cyan)
                    TextField(model.paletteMode == .url ? "URL or search" : "Launch, run, open a URL, or jump to a tile…", text: $query)
                        .textFieldStyle(.plain)
                        .font(Style.ui(17))
                        .focused($focused)
                        .onSubmit { run(items) }
                    Text(model.contextDirectory.abbreviatingHome)
                        .font(Style.mono(10)).foregroundStyle(Style.faint).lineLimit(1)
                }
                .padding(16)
                Divider().overlay(Style.hairline)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(i)
                                    .onTapGesture {
                                        item.run()
                                        dismiss()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
            .frame(width: 640)
            .background(.ultraThinMaterial)
            .background(Style.deck.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Style.ink.opacity(0.15)))
            .shadow(color: .black.opacity(0.6), radius: 50, y: 20)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.color)
                .frame(width: 28, height: 28)
                .background(item.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Style.ui(13, .medium)).foregroundStyle(Style.ink)
                Text(item.subtitle).font(Style.mono(10)).foregroundStyle(Style.dim).lineLimit(1)
            }
            Spacer()
            if selected { Text("↩").font(Style.mono(12)).foregroundStyle(Style.dim) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Style.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    private var items: [Item] {
        let workspace = model.workspace
        let q = query.trimmingCharacters(in: .whitespaces)
        let cwd = model.contextDirectory
        var out: [Item] = []

        if model.paletteMode == .url {
            if !q.isEmpty {
                out.append(Item(id: "url", symbol: "globe", color: Style.violet, title: "Open \(q)", subtitle: "New web tile") {
                    workspace.openBrowser(q)
                })
            }
            return out
        }

        let presets = workspace.presets.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.command ?? "").hasPrefix(q) }
        for p in presets {
            out.append(Item(id: "preset-\(p.name)", symbol: p.flavor.symbol, color: Style.accent(p.flavor),
                            title: "New \(p.name)", subtitle: (p.command ?? "login shell") + " · " + cwd.abbreviatingHome) {
                workspace.launch(command: p.command, cwd: cwd)
            })
        }
        if !q.isEmpty {
            let looksLikeURL = q.contains("://") || (q.contains(".") && !q.contains(" ") && !q.hasPrefix("."))
            if looksLikeURL {
                out.insert(Item(id: "url", symbol: "globe", color: Style.violet, title: "Open \(q)", subtitle: "New web tile") {
                    workspace.openBrowser(q)
                }, at: 0)
            }
            out.append(Item(id: "run", symbol: "play.fill", color: Style.cyan, title: "Run \(q)", subtitle: "New terminal tile in " + cwd.abbreviatingHome) {
                workspace.launch(command: q, cwd: cwd)
            })
            for tile in workspace.allTiles where tile.title.localizedCaseInsensitiveContains(q) || tile.subtitle.localizedCaseInsensitiveContains(q) {
                out.append(Item(id: "tile-\(tile.id)", symbol: "arrow.up.right.square", color: Style.state(tile.activity),
                                title: tile.title, subtitle: "Jump to tile · " + tile.subtitle) {
                    model.open(tile.id)
                })
            }
            if !looksLikeURL {
                out.append(Item(id: "search", symbol: "magnifyingglass", color: Style.violet, title: "Search the web for “\(q)”", subtitle: "New web tile") {
                    workspace.openBrowser(q)
                })
            }
        } else {
            out.append(Item(id: "url-mode", symbol: "globe", color: Style.violet, title: "Open Web Tile…", subtitle: "⌘L") {
                DispatchQueue.main.async {
                    model.paletteMode = .url
                    model.showPalette = true
                }
            })
            for tile in workspace.allTiles where tile.attention || tile.activity == .needsInput {
                out.append(Item(id: "tile-\(tile.id)", symbol: "exclamationmark.circle", color: Style.state(tile.activity),
                                title: tile.title, subtitle: (tile.detail ?? tile.activity.label)) {
                    model.open(tile.id)
                })
            }
        }
        return out
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        items[selection].run()
        dismiss()
    }

    private func dismiss() {
        model.showPalette = false
        model.paletteMode = .all
    }
}
