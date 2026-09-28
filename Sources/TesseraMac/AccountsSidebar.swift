import SwiftUI
import TesseraHost
import TesseraKit

/// Every connected provider's remaining balance or plan headroom, with one-click top-up.
struct AccountsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let usage = model.workspace.usage
        let server = model.server
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ACCOUNTS").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(Style.dim)
                Spacer()
                Button { usage.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Style.dim).help("Refresh balances")
                Button { openSettings() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Style.dim).help("Connect a provider")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(usage.orderedReadings) { reading in
                        UsageRow(reading: reading) { NSWorkspace.shared.open($0) }
                            .contextMenu {
                                Button("Refresh") {
                                    if let c = usage.configs.first(where: { $0.id == reading.id }) { usage.refresh(c) }
                                }
                                Button("Remove", role: .destructive) { usage.remove(id: reading.id) }
                            }
                    }
                    if usage.configs.count <= 1 {
                        Button { openSettings() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "link.badge.plus").font(.system(size: 18))
                                Text("Connect OpenAI, Anthropic, OpenRouter, DeepSeek…").font(Style.ui(11)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(Style.dim)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Style.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
            RemoteStatus(server: server)
                .padding(12)
        }
        .background(Style.deck.opacity(0.7))
        .overlay(alignment: .leading) { Rectangle().fill(Style.hairline).frame(width: 1) }
    }
}

struct RemoteStatus: View {
    let server: HostServer
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings() } label: {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(server.isRunning ? Style.mint : Style.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.isRunning ? (server.clientNames.isEmpty ? "Ready for iPhone" : server.clientNames.joined(separator: ", ")) : "iPhone link off")
                        .font(Style.ui(11, .semibold)).foregroundStyle(Style.ink)
                    Text(server.status).font(Style.mono(9)).foregroundStyle(Style.dim)
                }
                Spacer()
            }
            .padding(10)
            .background(Style.glass.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
