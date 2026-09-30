import SwiftUI

/// One machine at a glance: its name and, under it, temperature, memory and GPU power, with its
/// load beside them (`MachineLoads`, or whatever view of it the caller keeps current). The load is
/// drawn over room the words leave for it, so that redrawing it lays nothing out; pass
/// `vitals.face` and a sample that moves only the load doesn't touch the words either.
public struct MachineChip<Loads: View>: View {
    let vitals: MachineVitals
    var compact: Bool
    let loads: Loads

    public init(vitals: MachineVitals, compact: Bool = false, @ViewBuilder loads: () -> Loads) {
        self.vitals = vitals
        self.compact = compact
        self.loads = loads()
    }

    public var body: some View {
        let online = vitals.status == .ok
        HStack(spacing: Style.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Style.Space.xs) {
                    Dot(online ? Style.muted : vitals.status == .connecting ? Style.faint : Style.coral)
                    Text(vitals.name).font(Style.label).foregroundStyle(Style.ink).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    subtitle.lineLimit(1)
                    if compact, online { Text(MachineLoads.widestNumber).hidden().overlay { loads } }
                }
                .font(Style.caption)
                .foregroundStyle(Style.muted)
            }
            if !compact, online {
                Color.clear.frame(width: MachineLoads.size.width, height: MachineLoads.size.height).overlay { loads }
            }
        }
        .padding(.horizontal, Style.Space.m)
        .frame(height: Style.Metrics.control)
        .cardSurface()
        .opacity(online ? 1 : 0.7)
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
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text(" · ") + $1 }
    }
}

public extension MachineChip where Loads == MachineLoads {
    /// The chip of a client that has only the readings: its loads are meters, redrawn with it.
    init(vitals: MachineVitals, compact: Bool = false) {
        self.init(vitals: vitals, compact: compact) { MachineLoads(vitals: vitals, compact: compact) }
    }
}

/// A machine's load, beside its chip's words: CPU and GPU over the last while as sparklines (CPU
/// over GPU; level meters when no `trend` is kept) and a memory meter, or on a compact chip the
/// CPU as a number. One drawing, in the room the chip keeps for it.
public struct MachineLoads: View {
    /// The room a chip keeps for it, whatever it shows: two sparklines high.
    static let size = CGSize(width: Style.Metrics.spark.width + 2 * Style.Space.xs,
                             height: 2 * Style.Metrics.spark.height + Style.Space.xxs)
    /// On a compact chip: the widest number there is to show.
    static let widestNumber = " · 100%"

    let vitals: MachineVitals
    var trend: MachineTrend?
    var compact: Bool

    public init(vitals: MachineVitals, trend: MachineTrend? = nil, compact: Bool = false) {
        self.vitals = vitals
        self.trend = trend
        self.compact = compact
    }

    public var body: some View {
        Canvas { ctx, size in
            if compact {
                guard let cpu = vitals.cpu else { return }
                ctx.draw(Text(" · \(Int((cpu * 100).rounded()))%").font(Style.caption).foregroundStyle(Style.muted),
                         at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
                return
            }
            let bar = Style.Space.xs
            let memory = CGRect(x: size.width - bar, y: 0, width: bar, height: size.height)
            if let trend {
                let rows = trend.gpu.isEmpty ? [trend.cpu] : [trend.cpu, trend.gpu]
                let height = (size.height - Style.Space.xxs * CGFloat(rows.count - 1)) / CGFloat(rows.count)
                for (row, values) in rows.enumerated() {
                    Self.sparkline(values, in: CGRect(x: 0, y: CGFloat(row) * (height + Style.Space.xxs),
                                                      width: Style.Metrics.spark.width, height: height), ctx)
                }
            } else {
                Self.meter(vitals.cpu, in: memory.offsetBy(dx: -4 * bar, dy: 0), ctx)
                Self.meter(vitals.gpu, in: memory.offsetBy(dx: -2 * bar, dy: 0), ctx)
            }
            Self.meter(vitals.memory, warns: true, in: memory, ctx)
        }
    }

    /// A load's last samples as a line over a faint fill, idle at the bottom and flat out at the
    /// top, the latest at the right. Load is never an alarm: it is drawn in a neutral, brighter
    /// when busy.
    private static func sparkline(_ values: [Double], in rect: CGRect, _ ctx: GraphicsContext) {
        guard let last = values.last else { return }
        let color = last >= 0.7 ? Style.ink : Style.dim
        // A point per sample, half a line's width inside the rectangle.
        let step = rect.width / CGFloat(MachineTrend.length - 1)
        let points = values.enumerated().map { i, v in
            CGPoint(x: rect.maxX - CGFloat(values.count - 1 - i) * step, y: rect.minY + 0.5 + (rect.height - 1) * (1 - v))
        }
        var line = Path()
        line.addLines(points.count > 1 ? points : [CGPoint(x: rect.maxX - step, y: points[0].y), points[0]])
        var area = line
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        area.addLine(to: CGPoint(x: line.boundingRect.minX, y: rect.maxY))
        ctx.fill(area, with: .color(color.opacity(Style.Tint.strong)))
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }

    /// A slim vertical meter, brighter as it fills. Only one that `warns` (memory, which a machine
    /// can run out of) turns amber, then coral, near the top.
    private static func meter(_ value: Double?, warns: Bool = false, in rect: CGRect, _ ctx: GraphicsContext) {
        let v = min(1, max(0, value ?? 0))
        let color = warns && v >= 0.97 ? Style.coral : warns && v >= 0.9 ? Style.amber : v >= 0.7 ? Style.ink : Style.dim
        let track = Path(roundedRect: rect, cornerRadius: rect.width / 2)
        ctx.fill(track, with: .color(Style.hairline))
        var level = ctx
        level.clip(to: track)
        level.fill(Path(CGRect(x: rect.minX, y: rect.maxY - max(rect.width / 2, rect.height * v), width: rect.width, height: rect.height)),
                   with: .color(color))
    }
}

public extension MachineVitals {
    /// What a chip's words show, and nothing else: the loads its meters draw are left out and the
    /// memory is rounded to the gigabytes it is written in, so a sample that moves only a meter
    /// leaves this equal.
    var face: MachineVitals {
        var face = self
        (face.cpu, face.gpu, face.load, face.hottestSensor, face.cores, face.message) = (nil, nil, nil, nil, nil, nil)
        if let memory, let total = memoryTotalGB, total > 0 { face.memory = (memory * total).rounded() / total }
        return face
    }

    /// The full numbers, for a tooltip.
    var details: String {
        if status != .ok { return [name, message ?? status.rawValue].joined(separator: "\n") }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        var lines = [name]
        var cpuLine = "CPU \(pct(cpu))"
        if let cores { cpuLine += " · \(cores) cores" }
        if let load { cpuLine += " · load \(String(format: "%.1f", load))" }
        lines.append(cpuLine)
        var gpuLine = "GPU \(pct(gpu))"
        if let gpuName { gpuLine += " · \(gpuName)" }
        if let gpuPowerW { gpuLine += String(format: " · %.0f W GPU power", gpuPowerW) }
        lines.append(gpuLine)
        if let memory, let total = memoryTotalGB {
            lines.append(String(format: "Memory %@ · %.1f of %.0f GB", pct(memory), memory * total, total))
        }
        if let temperature {
            var line = String(format: "%@ %.0f °C", gpuName == nil || isLocal ? "Temperature" : "GPU", temperature)
            if let hottestSensor { line += String(format: " · hottest sensor %.0f °C", hottestSensor) }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
