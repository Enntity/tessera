import SwiftUI
import TesseraHost
import TesseraKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                HUDBar()
                HStack(spacing: 0) {
                    BoardView()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    if model.showSidebar {
                        AccountsSidebar()
                            .frame(width: 290)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            if model.showPalette {
                CommandPalette()
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .environment(\.tesseraPrivacy, model.privacyMode)
        .coordinateSpace(name: "window")
        .background(WindowAccessor { model.window = $0 })
        .ignoresSafeArea()
        .animation(.spring(duration: 0.25), value: model.showPalette)
    }
}

/// Takes whatever size it is offered without measuring its content. At the window's root this keeps
/// AppKit's min-size checks, and any change deep in the board, from re-measuring the whole tree.
struct FillProposal: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// The void behind the board: a faint lattice with a glow, so tiles float.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Style.void
            Canvas { ctx, size in
                let step: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    var y: CGFloat = 0
                    while y < size.height {
                        path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                        y += step
                    }
                    x += step
                }
                ctx.fill(path, with: .color(.white.opacity(0.05)))
            }
            RadialGradient(colors: [Style.cyan.opacity(0.07), .clear], center: .top, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Style.violet.opacity(0.05), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
    }
}

/// Captures the hosting NSWindow so we can convert between window and screen space.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.isMovableByWindowBackground = false
                w.titlebarAppearsTransparent = true
                w.backgroundColor = NSColor(Style.void)
                onWindow(w)
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HUDBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        let state = workspace.state
        HStack(spacing: 14) {
            Wordmark()
                .padding(.leading, 78) // clear the traffic lights
            Divider().frame(height: 18).overlay(Style.hairline)
            HStack(spacing: 8) {
                CountChip(value: state.needsInput.count, label: "need you", color: Style.amber, pulse: !state.needsInput.isEmpty) {
                    model.jumpToAttention()
                }
                CountChip(value: state.done, label: "done", color: Style.mint, pulse: false) {
                    model.jumpToAttention()
                }
                CountChip(value: state.working.count, label: "working", color: Style.cyan, pulse: false) {
                    withAnimation(.spring(duration: 0.35)) { workspace.filter = .all }
                }
            }
            Spacer()
            TabStrip()
            Spacer()
            MachineStrip()
            Button {
                model.paletteMode = .all
                model.showPalette = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New").font(Style.ui(12, .semibold))
                    Text("⌘K").font(Style.mono(10)).foregroundStyle(Style.faint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Style.cyan.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Style.cyan.opacity(0.35)))
                .foregroundStyle(Style.cyan)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { model.privacyMode.toggle() }
            } label: {
                Image(systemName: model.privacyMode ? "eye.slash.fill" : "eye")
                    .foregroundStyle(model.privacyMode ? Style.amber : Style.dim)
            }
            .buttonStyle(.plain)
            .help("Privacy mode (⇧⌘P): terminals and conversations stay lively but unreadable")
                        Button {
                withAnimation(.spring(duration: 0.3)) { model.showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right").foregroundStyle(model.showSidebar ? Style.ink : Style.dim)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(height: 44)
        .background(.ultraThinMaterial.opacity(0.35))
        .overlay(alignment: .bottom) { Rectangle().fill(Style.hairline).frame(height: 1) }
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            TesseraGlyph().frame(width: 16, height: 16)
            Text("TESSERA")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(Style.ink)
        }
    }
}

struct CountChip: View {
    let value: Int
    let label: String
    let color: Color
    let pulse: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(value)")
                    .font(Style.mono(12, .bold))
                    .contentTransition(.numericText())
                Text(label).font(Style.ui(11))
            }
            .foregroundStyle(value > 0 ? color : Style.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                if pulse {
                    Ambient(.pulse(color, cornerRadius: nil, low: 0.1, high: 0.28, period: 0.9))
                } else {
                    Capsule().fill((value > 0 ? color : Style.faint).opacity(0.1))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: value)
    }
}

/// Every watched machine as a chip, then the clock. Falls back to compact chips when space is short.
struct MachineStrip: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.workspace.machines
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                chips(monitor, compact: false)
                chips(monitor, compact: true)
            }
            Menu {
                let known = Set(monitor.remotes.compactMap(\.sshHost))
                let hosts = monitor.suggestedHosts().filter { !known.contains($0) }
                ForEach(hosts, id: \.self) { host in
                    Button(host) { monitor.add(host: host, name: nil) }
                }
                if !hosts.isEmpty { Divider() }
                Button("Other Host…") {
                    model.showAddMachine = true
                    openSettings()
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(Style.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Watch another machine over SSH")
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(Style.mono(13, .semibold))
                    .foregroundStyle(Style.ink)
                    .padding(.leading, 4)
            }
        }
    }

    private func chips(_ monitor: MachineMonitor, compact: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(monitor.ordered) { vitals in
                MachineChip(vitals: vitals, compact: compact)
                    .onTapGesture {
                        guard let host = monitor.config(vitals.id)?.sshHost else { return }
                        model.workspace.launch(command: "ssh \(host)", title: vitals.name)
                    }
                    .contextMenu {
                        if let host = monitor.config(vitals.id)?.sshHost {
                            Button("Open Terminal on \(vitals.name)") { model.workspace.launch(command: "ssh \(host)", title: vitals.name) }
                            Button("Stop Watching", role: .destructive) { monitor.remove(id: vitals.id) }
                        }
                    }
            }
        }
    }
}


/// All · Needs you · the user's own tabs · +. Tiles can be dropped onto a tab to file them.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        let workspace = model.workspace
        let needsUser = workspace.state.needsUser
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                TabChip(title: "All", count: workspace.order.count, attention: false,
                        selected: workspace.filter == .all, dropTile: { file($0, into: nil) }) { select(.all) }
                TabChip(title: "Needs you", count: needsUser.count, attention: false,
                        selected: workspace.filter == .attention, tint: Style.amber) { select(.attention) }
                if !workspace.groups.list.isEmpty {
                    Rectangle().fill(Style.hairline).frame(width: 1, height: 14).padding(.horizontal, 4)
                }
                ForEach(workspace.groups.list) { group in
                    let members = workspace.groups.members(of: group.id)
                    TabChip(title: group.name, count: members.filter(workspace.exists).count,
                            attention: !members.isDisjoint(with: needsUser),
                            selected: workspace.filter == .group(group.id), dropTile: { file($0, into: group.id) }) {
                        select(.group(group.id))
                    }
                        .contextMenu {
                            Button("Rename…") {
                                draft = group.name
                                renaming = group.id
                            }
                            Button("Delete Tab", role: .destructive) {
                                withAnimation(.spring(duration: 0.3)) { workspace.deleteGroup(group.id) }
                            }
                        }
                        .popover(isPresented: Binding(get: { renaming == group.id }, set: { if !$0 { renaming = nil } })) {
                            nameField("Tab name") { workspace.renameGroup(group.id, to: $0) }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Button {
                    draft = ""
                    naming = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Style.dim)
                .help("New tab — then drag tiles onto it")
                .popover(isPresented: $naming) {
                    nameField("New tab") { name in
                        withAnimation(.spring(duration: 0.3)) { _ = workspace.createGroup(named: name) }
                    }
                }
            }
            .padding(3)
        }
        .frame(maxWidth: 640)
        .fixedSize(horizontal: true, vertical: false)
        .background(Style.glass.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(Style.hairline))
        .animation(.spring(duration: 0.3), value: workspace.groups)
    }

    private func select(_ filter: Workspace.Filter) {
        withAnimation(.spring(duration: 0.35)) { model.workspace.filter = filter }
    }

    private func file(_ tileId: String, into groupId: String?) {
        withAnimation(.spring(duration: 0.4)) { model.workspace.move(tile: tileId, toGroup: groupId) }
    }

    private func nameField(_ prompt: String, commit: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .padding(10)
            .onSubmit {
                commit(draft)
                naming = false
                renaming = nil
            }
    }
}

struct TabChip: View {
    let title: String
    let count: Int
    let attention: Bool
    let selected: Bool
    var tint: Color = Style.cyan
    /// Accepts a tile dragged onto the tab.
    var dropTile: ((String) -> Void)?
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if attention {
                    Circle().fill(Style.amber).frame(width: 5, height: 5).shadow(color: Style.amber, radius: 3)
                }
                Text(title).font(Style.ui(12, selected ? .semibold : .medium)).lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(Style.mono(9.5, .semibold))
                        .foregroundStyle(selected ? tint : Style.faint)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(selected ? Style.ink : Style.dim)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(selected ? Style.ink.opacity(0.1) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(targeted ? Style.cyan : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: dropTile == nil ? nil : $targeted) { providers in
            guard let dropTile, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let id = obj as? String else { return }
                DispatchQueue.main.async { dropTile(id) }
            }
            return true
        }
    }
}
