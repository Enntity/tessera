import SwiftUI

/// One machine at a glance: its name and, under it, temperature and GPU power, with how busy it is
/// and how full its memory is beside them (`MachineLoads`, or whatever view of it the caller keeps current). The load is
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

    /// The numbers under the name. Heat colors the temperature alone; load and memory are the bars.
    private var subtitle: Text {
        guard vitals.status == .ok else { return Text(vitals.status == .connecting ? "connecting…" : "offline") }
        var parts: [Text] = []
        if let t = vitals.temperature {
            parts.append(Text("\(Int(t.rounded()))°").foregroundStyle(t >= 85 ? Style.coral : t >= 72 ? Style.amber : Style.muted))
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

/// How busy a machine is and how full its memory, beside its chip's words: two labelled bars, the
/// GPU (else the CPU) over memory, each with its percent (on a compact chip, the bars alone). One
/// drawing, in the room the chip keeps for it.
public struct MachineLoads: View {
    static let label = "GPU "
    static let number = " 100%"
    /// The room a chip keeps for it, whatever it shows.
    static let size = CGSize(width: Style.Metrics.meter.width + 2 * Style.Space.xl + 2 * Style.Space.xs + Style.Space.l,
                             height: 2 * Style.Space.l)
    /// On a compact chip: room for the bars alone.
    static let widestNumber = " ▁▁▁▁"

    let vitals: MachineVitals
    var compact: Bool

    public init(vitals: MachineVitals, compact: Bool = false) {
        self.vitals = vitals
        self.compact = compact
    }

    public var body: some View {
        Canvas { ctx, size in
            let rows: [(String, Double?, Bool)] = [(vitals.primaryLoad?.name ?? "CPU", vitals.primaryLoad?.value, false),
                                                   ("MEM", vitals.memory, true)]
            let rowHeight = size.height / 2
            for (i, (name, value, warns)) in rows.enumerated() {
                let mid = rowHeight * (CGFloat(i) + 0.5)
                if compact {
                    let bar = CGRect(x: Style.Space.xs, y: mid - Style.Metrics.meter.height / 2,
                                     width: size.width - Style.Space.xs, height: Style.Metrics.meter.height)
                    Self.bar(value, warns: warns, in: bar, ctx)
                    continue
                }
                ctx.draw(Text(name).font(Style.caption).foregroundStyle(Style.muted), at: CGPoint(x: 0, y: mid), anchor: .leading)
                let bar = CGRect(x: 2 * Style.Space.xl, y: mid - Style.Metrics.meter.height / 2,
                                 width: Style.Metrics.meter.width, height: Style.Metrics.meter.height)
                Self.bar(value, warns: warns, in: bar, ctx)
                let percent = value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
                ctx.draw(Text(percent).font(Style.caption).monospacedDigit().foregroundStyle(Self.color(value, warns: warns)),
                         at: CGPoint(x: size.width, y: mid), anchor: .trailing)
            }
        }
    }

    /// Cool to hot, so a glance says which machine has room: mint with headroom, amber busy, coral
    /// flat out. Memory, which a machine can run out of, keeps mint longer and turns later.
    static func color(_ value: Double?, warns: Bool) -> Color {
        guard let v = value else { return Style.dim }
        let (busy, full) = warns ? (0.8, 0.95) : (0.5, 0.85)
        return v >= full ? Style.coral : v >= busy ? Style.amber : Style.mint
    }

    private static func bar(_ value: Double?, warns: Bool, in rect: CGRect, _ ctx: GraphicsContext) {
        let v = min(1, max(0, value ?? 0))
        let track = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        ctx.fill(track, with: .color(Style.hairline))
        guard value != nil else { return }
        var level = ctx
        level.clip(to: track)
        level.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * v), height: rect.height)),
                   with: .color(color(value, warns: warns)))
    }
}

public extension MachineVitals {
    /// What a chip's words show, and nothing else: the load and memory its bars draw are left out,
    /// so a sample that moves only a bar leaves this equal.
    var face: MachineVitals {
        var face = self
        (face.cpu, face.gpu, face.memory, face.load, face.hottestSensor, face.cores, face.message) = (nil, nil, nil, nil, nil, nil, nil)
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
