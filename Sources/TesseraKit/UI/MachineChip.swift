import SwiftUI

/// One machine at a glance: name, temperature, memory, and CPU / GPU / MEM level bars.
public struct MachineChip: View {
    let vitals: MachineVitals
    var compact: Bool

    public init(vitals: MachineVitals, compact: Bool = false) {
        self.vitals = vitals
        self.compact = compact
    }

    public var body: some View {
        let online = vitals.status == .ok
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(online ? Style.mint : vitals.status == .connecting ? Style.dim : Style.coral)
                        .frame(width: 5, height: 5)
                    Text(vitals.name).font(Style.ui(10.5, .semibold)).foregroundStyle(Style.ink).lineLimit(1)
                }
                Text(subtitle).font(Style.mono(8.5)).foregroundStyle(temperatureColor).lineLimit(1)
            }
            if !compact, online {
                HStack(spacing: 3) {
                    LevelBar(value: vitals.cpu, label: "C")
                    LevelBar(value: vitals.gpu, label: "G")
                    LevelBar(value: vitals.memory, label: "M")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Style.glass.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Style.hairline))
        .opacity(online ? 1 : 0.7)
        .help(details)
    }

    private var subtitle: String {
        switch vitals.status {
        case .connecting: return "connecting…"
        case .unreachable: return "offline"
        case .ok:
            var parts: [String] = []
            if let t = vitals.temperature { parts.append("\(Int(t.rounded()))°") }
            if let m = vitals.memory, let total = vitals.memoryTotalGB {
                parts.append("\(Int((m * total).rounded()))/\(Int(total.rounded()))G")
            }
            if let w = vitals.gpuPowerW { parts.append("\(Int(w.rounded()))W") }
            if compact, let c = vitals.cpu { parts.append("\(Int((c * 100).rounded()))%") }
            return parts.joined(separator: " · ")
        }
    }

    private var temperatureColor: Color {
        guard vitals.status == .ok, let t = vitals.temperature else { return Style.dim }
        return t >= 85 ? Style.coral : t >= 72 ? Style.amber : Style.dim
    }

    /// The full numbers, as a tooltip.
    private var details: String {
        if vitals.status != .ok { return [vitals.name, vitals.message ?? vitals.status.rawValue].joined(separator: "\n") }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        var lines = [vitals.name]
        var cpu = "CPU \(pct(vitals.cpu))"
        if let cores = vitals.cores { cpu += " · \(cores) cores" }
        if let load = vitals.load { cpu += " · load \(String(format: "%.1f", load))" }
        lines.append(cpu)
        var gpu = "GPU \(pct(vitals.gpu))"
        if let name = vitals.gpuName { gpu += " · \(name)" }
        if let w = vitals.gpuPowerW { gpu += String(format: " · %.0f W GPU power", w) }
        lines.append(gpu)
        if let m = vitals.memory, let total = vitals.memoryTotalGB {
            lines.append(String(format: "Memory %@ · %.1f of %.0f GB", pct(m), m * total, total))
        }
        if let t = vitals.temperature {
            var line = String(format: "%@ %.0f °C", vitals.gpuName == nil || vitals.isLocal ? "Temperature" : "GPU", t)
            if let h = vitals.hottestSensor { line += String(format: " · hottest sensor %.0f °C", h) }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// A slim vertical meter: cyan when calm, amber when busy, coral when pinned.
struct LevelBar: View {
    let value: Double?
    let label: String

    var body: some View {
        let v = min(1, max(0, value ?? 0))
        let color = v >= 0.9 ? Style.coral : v >= 0.7 ? Style.amber : Style.cyan
        VStack(spacing: 1) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Style.hairline).frame(width: 5, height: 18)
                Capsule().fill(color).frame(width: 5, height: max(2, 18 * v))
                    .shadow(color: color.opacity(0.6), radius: v > 0.05 ? 2 : 0)
            }
            Text(label).font(Style.mono(6.5, .bold)).foregroundStyle(Style.faint)
        }
    }
}
