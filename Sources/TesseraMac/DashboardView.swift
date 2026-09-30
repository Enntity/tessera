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
                    VStack(spacing: 0) {
                        TabStrip()
                        BoardView()
                    }
                    .overlay(alignment: .bottom) {
                        if let toast = model.closedToast {
                            UndoToast(toast: toast)
                                .padding(.bottom, Style.Space.xxl)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    if model.showSidebar {
                        AccountsSidebar()
                            .frame(width: Style.Metrics.sidebar)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            if model.showPalette {
                CommandPalette()
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .environment(\.tesseraPrivacy, model.privacyMode)
        .tint(Style.control)
        .coordinateSpace(name: "window")
        .background(WindowAccessor { model.window = $0 })
        .ignoresSafeArea()
        .animation(Style.Motion.quick, value: model.showPalette)
        .onChange(of: model.showPalette) { _, shown in if !shown { model.restoreFocus() } }
    }
}

/// After a close: what was closed and the way back, for a few seconds. (Undo stays on the Edit
/// menu.)
struct UndoToast: View {
    @Environment(AppModel.self) private var model
    let toast: ClosedToast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Style.Space.m) {
            Text(toast.text).font(Style.ui(.label, .medium)).foregroundStyle(Style.dim).lineLimit(1)
            Button { model.reopen(toast.ids) } label: {
                HStack(alignment: .firstTextBaseline, spacing: Style.Space.xs) {
                    Text("Undo").font(Style.label).foregroundStyle(Style.ink)
                    Text("⌘Z").font(Style.caption).foregroundStyle(Style.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Style.Space.l)
        .frame(height: Style.Metrics.control)
        .overlaySurface(Capsule())
        .task(id: toast) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { model.dismiss(toast) }
        }
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

/// The void behind the board: a faint lattice under a glow, so tiles float.
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
            // A cool glow from above, in no state's color.
            RadialGradient(colors: [Style.control.opacity(Style.Tint.wash), .clear], center: .top, startRadius: 0, endRadius: 900)
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
                // Its window must not become the frame the real app opens with next time.
                if Preferences.isDevelopmentCopy { w.setFrameAutosaveName("") }
                onWindow(w)
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The top bar: the mark and what is going on at the left, the machines and what can be started at
/// the right.
struct HUDBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Style.Space.l) {
            Wordmark()
                .padding(.leading, 78) // clear the traffic lights
            StateCounters()
            Spacer(minLength: Style.Space.l)
            MachineStrip()
            Button {
                model.paletteMode = .all
                model.showPalette = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                    Image(systemName: "plus")
                    Text("New")
                    Text("⌘K").font(Style.caption).foregroundStyle(Style.muted)
                }
            }
            .buttonStyle(.capsule)
            HStack(spacing: 0) {
                toggle(model.privacyMode ? "eye.slash.fill" : "eye", on: model.privacyMode,
                       help: "Privacy mode (⇧⌘P): terminals and conversations stay lively but unreadable") { model.togglePrivacy() }
                toggle("sidebar.right", on: model.showSidebar, help: "Accounts (⌘\\)") { model.toggleSidebar() }
            }
        }
        .padding(.trailing, Style.Space.l)
        .frame(height: Style.Metrics.hud)
        .chromeSurface(rule: .bottom)
    }

    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Style.body)
                .foregroundStyle(on ? Style.ink : Style.dim)
                .frame(width: Style.Metrics.control, height: Style.Metrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: Style.Space.m) {
            TesseraGlyph().frame(width: 16, height: 16)
            // The one text outside the type ramp.
            Text("TESSERA")
                .font(Style.ui(12, .heavy))
                .tracking(3)
                .foregroundStyle(Style.ink)
        }
    }
}

/// What is going on, as counters: each opens the next tile in its state, oldest first. A state
/// nothing is in has no counter.
struct StateCounters: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.workspace.state
        HStack(spacing: Style.Space.s) {
            ForEach([(TileActivity.needsInput, state.needsInput), (.failed, state.failed), (.done, state.done), (.working, state.working)],
                    id: \.0) { activity, ids in
                if !ids.isEmpty {
                    CountChip(activity: activity, count: ids.count) { model.jump(to: ids) }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .animation(Style.Motion.standard, value: state)
    }
}

struct CountChip: View {
    let activity: TileActivity
    let count: Int
    let action: () -> Void

    var body: some View {
        let color = Style.state(activity)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Style.Space.xs) {
                Text("\(count)").font(Style.mono(.label, .bold)).contentTransition(.numericText())
                Text(activity.label).font(Style.label)
            }
            .foregroundStyle(color)
            .padding(.horizontal, Style.Space.gutter)
            .frame(height: Style.Metrics.control)
            .background {
                // A question waiting breathes; the rest hold still.
                if activity == .needsInput {
                    Ambient(.pulse(color, low: Style.Tint.fill, high: Style.Tint.strong))
                } else {
                    Capsule().fill(color.opacity(Style.Tint.fill))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Every watched machine as a chip, then the clock. When space is short the chips go compact, and
/// when there is none they go: a chip is whole or not there.
struct MachineStrip: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = model.workspace.machines
        HStack(spacing: Style.Space.s) {
            ViewThatFits(in: .horizontal) {
                chips(monitor, compact: false)
                chips(monitor, compact: true)
                Color.clear.frame(width: 0)
            }
            Menu {
                let hosts = monitor.unwatchedHosts
                ForEach(hosts, id: \.self) { host in
                    Button(host) { monitor.add(host: host, name: nil) }
                }
                if !hosts.isEmpty { Divider() }
                Button("Other Host…") {
                    model.showAddMachine = true
                    openSettings()
                }
            } label: {
                Image(systemName: "plus").font(Style.label).foregroundStyle(Style.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Style.dim)
            .fixedSize()
            .help("Watch another machine over SSH")
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(Style.mono(.body, .semibold))
                    .foregroundStyle(Style.ink)
                    .padding(.leading, Style.Space.xs)
            }
        }
    }

    private func chips(_ monitor: MachineMonitor, compact: Bool) -> some View {
        HStack(spacing: Style.Space.s) {
            ForEach(monitor.ordered) { vitals in
                let host = monitor.config(vitals.id)?.sshHost
                let connect = { model.create { $0.launch(command: host.map { "ssh \($0)" }, title: vitals.name) } }
                MachineChip(vitals: vitals, compact: compact)
                    .fixedSize()
                    .onTapGesture { if host != nil { connect() } }
                    .contextMenu {
                        if host != nil {
                            Button("Open Terminal on \(vitals.name)", action: connect)
                            Button("Stop Watching", role: .destructive) { monitor.remove(id: vitals.id) }
                        }
                    }
            }
        }
    }
}

/// All · Needs you · the user's own tabs · +, in a strip over the board. Tiles can be dropped onto
/// a tab to file them.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        let workspace = model.workspace
        let state = workspace.state
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.Space.xxs) {
                TabChip(title: "All", count: workspace.order.count,
                        selected: workspace.filter == .all, dropTile: { file($0, into: nil) }) { model.onBoard { $0.filter = .all } }
                TabChip(title: TileActivity.needsInput.label, count: state.queue.count, waiting: state.waiting(in: state.needsUser),
                        selected: workspace.filter == .attention) { model.onBoard { $0.filter = .attention } }
                if !workspace.groups.list.isEmpty {
                    Hairline(.vertical).frame(height: Style.Space.xl).padding(.horizontal, Style.Space.xs)
                }
                ForEach(workspace.groups.list) { group in
                    let members = workspace.groups.members(of: group.id)
                    TabChip(title: group.name, count: members.filter(workspace.exists).count,
                            waiting: state.waiting(in: members),
                            selected: workspace.filter == .group(group.id), dropTile: { file($0, into: group.id) }) {
                        model.onBoard { $0.filter = .group(group.id) }
                    }
                        .contextMenu {
                            Button("Rename…") {
                                draft = group.name
                                renaming = group.id
                            }
                            Button("Delete Tab", role: .destructive) {
                                withAnimation(Style.Motion.standard) { workspace.deleteGroup(group.id) }
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
                        .font(Style.label)
                        .frame(width: Style.Metrics.control, height: Style.Metrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Style.dim)
                .help("New tab — then drag tiles onto it")
                .popover(isPresented: $naming) {
                    nameField("New tab") { name in model.onBoard { _ = $0.createGroup(named: name) } }
                }
            }
            .padding(.horizontal, Style.Space.l)
        }
        .frame(height: Style.Metrics.strip)
        .chromeSurface(rule: .bottom)
        .animation(Style.Motion.standard, value: workspace.groups)
    }

    private func file(_ tileId: String, into groupId: String?) {
        withAnimation(Style.Motion.standard) { model.workspace.move(tile: tileId, toGroup: groupId) }
    }

    private func nameField(_ prompt: String, commit: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .padding(Style.Space.gutter)
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
    /// The most pressing state waiting on the user among the tab's tiles: its dot takes that colour.
    var waiting: TileActivity?
    let selected: Bool
    /// Accepts a tile dragged onto the tab.
    var dropTile: ((String) -> Void)?
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Style.Space.s) {
                if let waiting { Circle().fill(Style.state(waiting)).frame(width: 5, height: 5) }
                HStack(alignment: .firstTextBaseline, spacing: Style.Space.s) {
                    Text(title).font(Style.ui(.label, selected ? .semibold : .medium)).lineLimit(1)
                    if count > 0 {
                        Text("\(count)").font(Style.caption)
                            .foregroundStyle(selected ? Style.dim : Style.muted)
                            .contentTransition(.numericText())
                    }
                }
            }
            .foregroundStyle(selected ? Style.ink : Style.dim)
            .padding(.horizontal, Style.Space.gutter)
            .frame(height: Style.Metrics.control)
            .background(selected ? Style.Neutral.selected : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(targeted ? Style.Neutral.focus : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: dropTile == nil ? nil : $targeted) { providers in
            guard let dropTile else { return false }
            return providers.loadTileId { dropTile($0) }
        }
    }
}
