import SwiftUI
import TesseraKit

/// The phone board: what needs you first, then everything else as live mini tiles.
struct BoardScreen: View {
    @Environment(HostStore.self) private var store
    @Environment(RemoteSession.self) private var session
    @State private var filter: TileKind?
    @State private var showUsage = false
    @State private var showLaunch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Style.Space.xl) {
                    ConnectionBanner()
                    if !session.attentionTiles.isEmpty {
                        SectionLabel(text: TileActivity.needsYouLabel, color: Style.amber, count: session.attentionTiles.count)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Style.Space.l) {
                                ForEach(session.attentionTiles) { tile in
                                    NavigationLink(value: tile.id) {
                                        LiveTile(info: tile, compact: false).frame(width: 300, height: 210)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, Style.Space.xl)
                        }
                        .padding(.horizontal, -Style.Space.xl)
                    }
                    Picker("Show", selection: $filter) {
                        Text("All").tag(TileKind?.none)
                        Text("Terminals").tag(TileKind?.some(.terminal))
                        Text("Apps").tag(TileKind?.some(.agentSession))
                        Text("Web").tag(TileKind?.some(.browser))
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: Style.Space.gutter)], spacing: Style.Space.gutter) {
                        ForEach(session.tiles.filter { filter == nil || $0.kind == filter }) { tile in
                            NavigationLink(value: tile.id) {
                                LiveTile(info: tile, compact: true).frame(height: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Style.Space.xl)
                .animation(Style.Motion.standard, value: session.tiles.map(\.id))
                .animation(Style.Motion.standard, value: session.attentionTiles.map(\.id))
            }
            .background(Style.void)
            .refreshable { session.send(.refreshUsage) }
            .navigationTitle(session.hostName ?? store.host?.name ?? "Tessera")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TileDetail(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showUsage = true } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLaunch = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showUsage) { UsageScreen() }
            .sheet(isPresented: $showLaunch) { LaunchSheet() }
        }
    }
}

struct SectionLabel: View {
    let text: String
    let color: Color
    var count: Int?

    var body: some View {
        HStack(spacing: Style.Space.s) {
            Text(text).font(Style.ui(11, .heavy)).tracking(2).textCase(.uppercase)
            if let count { Text("\(count)").font(Style.mono(11, .bold)) }
        }
        .foregroundStyle(color)
    }
}

struct ConnectionBanner: View {
    @Environment(HostStore.self) private var store
    @Environment(RemoteSession.self) private var session

    var body: some View {
        switch session.state {
        case .connected:
            if let notice = session.notice {
                Label(notice, systemImage: "arrow.down.app").font(Style.ui(12)).foregroundStyle(Style.amber)
            }
        case .connecting, .idle:
            HStack(spacing: Style.Space.m) {
                ProgressView()
                Text("Connecting to \(store.host?.name ?? "your Mac")…").font(Style.ui(13)).foregroundStyle(Style.dim)
            }
        case .failed(let why):
            HStack(spacing: Style.Space.gutter) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Style.coral)
                VStack(alignment: .leading, spacing: Style.Space.xxs) {
                    Text("Can't reach \(store.host?.name ?? "your Mac")").font(Style.ui(13, .semibold))
                    Text(why).font(Style.mono(11)).foregroundStyle(Style.dim)
                }
                Spacer()
                Menu {
                    Button("Retry") { session.resume() }
                    Button("Forget this Mac", role: .destructive) { store.forget() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .padding(Style.Space.l)
            .background(Style.coral.opacity(Style.Tint.fill), in: Style.shape(Style.Radius.m))
        }
    }
}

/// A tile that streams its content only while it is on screen.
struct LiveTile: View {
    @Environment(RemoteSession.self) private var session
    let info: TileInfo
    let compact: Bool

    var body: some View {
        TileCard(info: info, compact: compact) {
            switch info.kind {
            case .terminal:
                if let mirror = session.mirrors[info.id] {
                    TerminalThumbnail(terminal: mirror.terminal, revision: mirror.revision).equatable().terminalTileInset()
                } else {
                    Style.terminalBackground
                }
            case .agentSession:
                ConversationThumbnail(snapshot: session.conversations[info.id], flavor: info.flavor,
                                      maxItems: compact ? 4 : 6, fontScale: compact ? 0.85 : 1)
            case .browser:
                VStack(spacing: Style.Space.s) {
                    Image(systemName: "globe").font(Style.ui(22)).foregroundStyle(Style.accent(.web))
                    Text(info.subtitle).font(Style.mono(10)).foregroundStyle(Style.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { session.setVisible(info.id, true) }
        .onDisappear { session.setVisible(info.id, false) }
    }
}

struct TileDetail: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.openURL) private var openURL
    let id: String

    var body: some View {
        let info = session.tiles.first { $0.id == id }
        Group {
            switch info?.kind {
            case .terminal: TerminalScreen(id: id)
            case .agentSession:
                ConversationDetail(snapshot: session.conversations[id])
                    .background(Style.deck)
            case .browser:
                VStack(spacing: Style.Space.l) {
                    Image(systemName: "globe").font(Style.ui(40)).foregroundStyle(Style.accent(.web))
                    Text(info?.url ?? "").font(Style.mono(12)).foregroundStyle(Style.dim).multilineTextAlignment(.center)
                    if let url = info?.url.flatMap(URL.init(string:)) {
                        Button("Open in Safari") { openURL(url) }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                Text("This tile was closed on the Mac.").foregroundStyle(Style.dim)
            }
        }
        .navigationTitle(info?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A tile closed on the Mac has nothing left to act on.
            if let kind = info?.kind {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { session.action(.openOnHost, on: id) } label: { Label("Open on Mac", systemImage: "desktopcomputer") }
                        if kind == .terminal {
                            Button { session.action(.restart, on: id) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        }
                        Button(role: .destructive) { session.action(.close, on: id) } label: {
                            Label(kind.closeLabel, systemImage: kind.closeSymbol)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .onAppear {
            session.setVisible(id, true)
            session.action(.acknowledge, on: id)
        }
        .onDisappear { session.setVisible(id, false) }
    }
}
