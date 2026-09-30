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
        HStack(spacing: Style.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Style.Space.xs) {
                    Circle()
                        .fill(online ? Style.muted : vitals.status == .connecting ? Style.faint : Style.coral)
                        .frame(width: 5, height: 5)
                    Text(vitals.name).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                }
                subtitle.font(Style.caption).foregroundStyle(Style.muted).lineLimit(1)
            }
            if !compact, online {
                HStack(spacing: Style.Space.xs) {
                    LevelBar(value: vitals.cpu)
                    LevelBar(value: vitals.gpu)
                    LevelBar(value: vitals.memory, warns: true)
                }
            }
        }
        .padding(.horizontal, Style.Space.m)
        .frame(height: Style.Metrics.control)
        .cardSurface()
        .opacity(online ? 1 : 0.7)
        .help(details)
    }

    /// The numbers under the name. Heat colors the temperature alone.
    private var subtitle: Text {
        guard vitals.status == .ok else { return Text(vitals.status == .connecting ? "connecting…" : "offline") }
        var parts: [Text] = []
        if let t = vitals.temperature {
            parts.append(Text("\(Int(t.rounded()))°").foregroundStyle(t >= 85 ? Style.coral : t >= 72 ? Style.amber : Style.muted))
        }
        if let m = vitals.memory, let total = vitals.memoryTotalGB {
            parts.append(Text("\(Int((m * total).rounded()))/\(Int(total.rounded()))G"))
        }
        if let w = vitals.gpuPowerW { parts.append(Text("\(Int(w.rounded()))W")) }
        if compact, let c = vitals.cpu { parts.append(Text("\(Int((c * 100).rounded()))%")) }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text(" · ") + $1 }
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

/// A slim vertical meter, brighter as it fills. Load is never an alarm; only a meter that `warns`
/// (memory, which a machine can run out of) turns amber, then coral, near the top.
struct LevelBar: View {
    let value: Double?
    var warns = false

    var body: some View {
        let v = min(1, max(0, value ?? 0))
        let color = warns && v >= 0.97 ? Style.coral : warns && v >= 0.9 ? Style.amber : v >= 0.7 ? Style.ink : Style.dim
        ZStack(alignment: .bottom) {
            Capsule().fill(Style.hairline).frame(width: 4, height: 18)
            Capsule().fill(color).frame(width: 4, height: max(2, 18 * v))
        }
    }
}
