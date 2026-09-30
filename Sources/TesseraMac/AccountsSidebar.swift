import SwiftUI
import TesseraHost
import TesseraKit

/// Every connected provider's remaining balance or plan headroom, with one-click top-up.
struct AccountsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// The row being dragged and when; rows reorder live as it passes over them. SwiftUI has no
    /// drag-ended callback for drops outside the list, so a stale marker simply expires.
    @State private var dragging: (id: String, at: Date)?

    var body: some View {
        let usage = model.workspace.usage
        let server = model.server
        VStack(alignment: .leading, spacing: 0) {
            // As tall as the tab strip beside it, so the first card lines up with the first row of tiles.
            HStack(spacing: Style.Space.gutter) {
                Text("Accounts").micro()
                Spacer()
                Button { usage.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh balances")
                Button { addAccount() } label: { Image(systemName: "plus") }
                    .help("Connect a provider")
            }
            .buttonStyle(.plain)
            .font(Style.label)
            .foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.l)
            .frame(height: Style.Metrics.strip)
            .overlay(alignment: .bottom) { Hairline() }

            ScrollView {
                VStack(spacing: Style.Space.m) {
                    ForEach(usage.orderedReadings) { reading in
                        UsageRow(reading: reading, onTopUp: { NSWorkspace.shared.open($0) }) { fix in
                            model.create { $0.launch(command: fix.command) }
                            usage.fixStarted(reading.id)
                        }
                            .help("Drag to reorder")
                            .onDrag {
                                dragging = (reading.id, Date())
                                return NSItemProvider(object: ("account:" + reading.id) as NSString)
                            }
                            .onDrop(of: [.text], delegate: AccountDropDelegate(target: reading.id, usage: usage, dragging: $dragging))
                            .contextMenu {
                                Button("Refresh") {
                                    if let c = usage.configs.first(where: { $0.id == reading.id }) { usage.refresh(c) }
                                }
                                Button("Remove", role: .destructive) { usage.remove(id: reading.id) }
                            }
                    }
                    if usage.configs.count <= 1 {
                        Button { addAccount() } label: {
                            VStack(spacing: Style.Space.s) {
                                Image(systemName: "link.badge.plus").font(Style.title)
                                Text("Connect OpenAI, Anthropic, OpenRouter, DeepSeek…").font(Style.ui(.label)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(Style.dim)
                            .frame(maxWidth: .infinity)
                            .padding(Style.Space.xl)
                            .overlay(Style.shape(Style.Radius.m).strokeBorder(Style.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Style.Space.l)
            }

            RemoteStatus(server: server)
                .padding(Style.Space.l)
        }
        .chromeSurface(rule: .leading)
    }
}

/// The iPhone link: who is connected, or that it is off; a second line only when it says more
/// (where it listens, why it failed).
struct RemoteStatus: View {
    let server: HostServer
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings() } label: {
            HStack(spacing: Style.Space.gutter) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(Style.body)
                    .foregroundStyle(server.isRunning ? Style.ink : Style.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server.isRunning ? (server.clientNames.isEmpty ? "Ready for iPhone" : server.clientNames.joined(separator: ", ")) : "iPhone link off")
                        .font(Style.label).foregroundStyle(Style.ink)
                    if server.isRunning {
                        Text(server.status).foregroundStyle(Style.muted)
                    } else if let failure = server.failure {
                        Text(failure).foregroundStyle(Style.coral).lineLimit(2)
                    }
                }
                .font(Style.caption)
                Spacer()
            }
            .padding(Style.Space.gutter)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension AccountsSidebar {
    private func addAccount() {
        model.showAddAccount = true
        openSettings()
    }
}

struct AccountDropDelegate: DropDelegate {
    let target: String
    let usage: UsageService
    @Binding var dragging: (id: String, at: Date)?

    func dropEntered(info: DropInfo) {
        guard let drag = dragging, Date().timeIntervalSince(drag.at) < 20, drag.id != target else { return }
        withAnimation(Style.Motion.standard) { usage.move(drag.id, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
