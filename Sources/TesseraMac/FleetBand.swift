import SwiftUI
import TesseraHost
import TesseraKit

/// Who holds the shared hardware a LLooM head schedules, one chip per resource, over the board.
/// Jobs are tiles; this is the lease view: free, held (by whom, for how long, who waits), or
/// needing someone (a lease running out, a restore that failed).
struct FleetBand: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        let fleet = model.workspace.fleet
        HStack(spacing: Style.Space.s) {
            Image(systemName: AgentFlavor.lloom.symbol)
                .font(Style.ui(.caption, .semibold))
                .foregroundStyle(Style.accent(.lloom))
                .help("Shared resources observed through Accord")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Style.Space.xxs) {
                    ForEach(fleet.lanes) { FleetLaneChip(lane: $0) }
                }
            }
            Spacer(minLength: 0)
            status(fleet)
        }
        .padding(.horizontal, Style.Space.gutter)
        .frame(height: Style.Metrics.strip)
        .chromeSurface(rule: .bottom)
        .contextMenu { Button("Fleet Settings…") { openSettings() } }
    }

    @ViewBuilder private func status(_ fleet: FleetService) -> some View {
        switch fleet.status {
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .font(Style.ui(.caption))
                .foregroundStyle(Style.coral)
                .lineLimit(1)
                .help(fleet.updatedAt.map { "Showing the schedule from \($0.shortAge()) ago" } ?? why)
        case .loading:
            Text("Connecting…").font(Style.ui(.caption)).foregroundStyle(Style.dim)
        case .ok, .off:
            EmptyView()
        }
    }
}

struct FleetLaneChip: View {
    let lane: LLoomSchedule.Lane

    var body: some View {
        HStack(spacing: Style.Space.s) {
            Dot(color, lit: lane.state != .free)
            Text(lane.label).font(Style.ui(.label, .semibold)).foregroundStyle(Style.ink)
            Text(summary).font(Style.caption).foregroundStyle(Style.dim)
        }
        .lineLimit(1)
        .padding(.horizontal, Style.Space.gutter)
        .frame(height: Style.Metrics.control)
        .fixedSize()
        .overlay(Capsule().strokeBorder(Style.Neutral.border))
        .contentShape(Capsule())
        .help(lane.help)
    }

    private var color: Color {
        switch lane.state {
        case .free: Style.muted
        case .held: Style.cyan
        case .attention: Style.amber
        case .unusable: Style.coral
        }
    }

    private var summary: String {
        guard !lane.holders.isEmpty else {
            return lane.state == .unusable ? "unknown" : lane.capacity > 1 ? "unclaimed · 0/\(lane.capacity)" : "unclaimed"
        }
        var parts = [lane.holders.joined(separator: ", ")]
        if lane.capacity > 1 { parts.append("\(lane.holders.count)/\(lane.capacity)") }
        if let status = lane.status { parts.append(status) }
        else if let left = lane.remaining { parts.append(left > 0 ? "\(Date().addingTimeInterval(-left).shortAge()) left" : "overdue") }
        if lane.queued > 0 { parts.append("+\(lane.queued) waiting") }
        return parts.joined(separator: " · ")
    }
}

/// The LLooM head Tessera follows for the Fleet band and job tiles.
struct FleetSettings: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var key = ""

    var body: some View {
        let fleet = model.workspace.fleet
        VStack(alignment: .leading, spacing: Style.Space.l) {
            Form {
                Toggle("Show Accord fleet", isOn: Binding(get: { fleet.isVisible }, set: { fleet.isVisible = $0 }))
                TextField("LLooM adapter in Accord", text: $url, prompt: Text("http://lloom.example:8100"))
                SecureField("Admin key", text: $key, prompt: Text(fleet.hasKey ? "saved in Keychain" : "required"))
            }
            .formStyle(.columns)
            HStack {
                status(fleet)
                Spacer()
                if fleet.config != nil {
                    Button("Hide Fleet") {
                        fleet.disconnect()
                        url = ""
                        key = ""
                    }
                }
                Button(fleet.config == nil ? "Connect" : "Save") {
                    if fleet.connect(url: url, key: key) { key = "" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(LLoomSchedule.baseURL(url) == nil || (key.isEmpty && !fleet.hasKey))
            }
            Toggle("Show agents' jobs as tiles", isOn: Binding(get: { fleet.showJobs }, set: { fleet.showJobs = $0 }))
                .toggleStyle(.switch)
            Text("Off: only jobs that fail and leases that need you appear, in Needs you.")
                .font(Style.ui(.label)).foregroundStyle(Style.dim)
            Text("Accord supplies shared resources, reservations and jobs. Connect an existing LLooM scheduler here to observe its serving jobs and leases through Accord. Existing LLooM ownership stays authoritative until its reservation adapter is explicitly enabled.")
                .font(Style.ui(.label)).foregroundStyle(Style.dim)
            Spacer()
        }
        .padding(Style.Space.xl)
        .onAppear { url = fleet.config?.url ?? "" }
    }

    @ViewBuilder private func status(_ fleet: FleetService) -> some View {
        switch fleet.status {
        case .off: Text("Not connected").font(Style.ui(.label)).foregroundStyle(Style.dim)
        case .loading: Text("Connecting…").font(Style.ui(.label)).foregroundStyle(Style.dim)
        case .ok: Text("Connected · \(fleet.lanes.count) resources").font(Style.ui(.label)).foregroundStyle(Style.mint)
        case .failed(let why): Text(why).font(Style.ui(.label)).foregroundStyle(Style.coral).lineLimit(2)
        }
    }
}
