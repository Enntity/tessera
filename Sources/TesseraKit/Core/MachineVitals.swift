import Foundation

/// A machine the board watches: this Mac, or a Linux host reached over SSH.
public struct MachineConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// An SSH destination as typed at a shell (`gpu-box-1`, `me@10.0.0.4`). Nil for this Mac.
    public var sshHost: String?

    public init(id: String = UUID().uuidString, name: String, sshHost: String?) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
    }

    /// Host strings go to `ssh` as an argument, never through a shell; still refuse anything that
    /// could read as an option or carry odd characters.
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count <= 255
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._@-:[]".contains($0)) }
    }
}

public struct MachineVitals: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case connecting, ok, unreachable }

    public var id: String
    public var name: String
    public var isLocal: Bool
    public var status: Status
    public var message: String?
    /// 0...1
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public var memoryTotalGB: Double?
    public var temperature: Double?
    /// Hottest board sensor, when it differs from `temperature` (shown in details).
    public var hottestSensor: Double?
    public var gpuName: String?
    public var gpuPowerW: Double?
    public var load: Double?
    public var cores: Int?

    public init(id: String, name: String, isLocal: Bool, status: Status = .connecting) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.status = status
    }

    /// Rounds readings to what the chip shows (whole percent, degrees and watts; load to a tenth),
    /// so a poll that changes nothing visible leaves the value equal and re-renders nothing.
    public mutating func quantize() {
        func percent(_ v: Double?) -> Double? { v.map { ($0 * 100).rounded() / 100 } }
        cpu = percent(cpu)
        gpu = percent(gpu)
        memory = percent(memory)
        temperature = temperature?.rounded()
        hottestSensor = hottestSensor?.rounded()
        gpuPowerW = gpuPowerW?.rounded()
        load = load.map { ($0 * 10).rounded() / 10 }
    }
}

/// Parses the tagged lines `RemoteVitals.script` prints on a Linux host.
public enum RemoteVitals {
    /// Cheap, dependency-free probe: /proc for CPU and memory, thermal zones for CPU temperature,
    /// nvidia-smi when present for the GPU. Each line is `@tag value`.
    public static let script = """
    echo "@stat $(head -1 /proc/stat)"; \
    awk '/^MemTotal:/{print "@memtotal "$2} /^MemAvailable:/{print "@memavail "$2}' /proc/meminfo; \
    echo "@load $(cut -d' ' -f1 /proc/loadavg)"; echo "@ncpu $(nproc)"; \
    echo "@ctemp $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)"; \
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,power.draw \
    --format=csv,noheader,nounits 2>/dev/null | sed 's/^/@gpu /'; true
    """

    public struct CPUSample: Hashable, Sendable {
        public var busy: UInt64
        public var total: UInt64

        /// Utilisation between two samples of the aggregate `cpu` line.
        public func utilization(since previous: CPUSample?) -> Double? {
            guard let previous, total > previous.total else { return nil }
            let dt = Double(total - previous.total)
            return min(1, max(0, Double(busy &- previous.busy) / dt))
        }
    }

    public struct Reading: Hashable, Sendable {
        public var cpuSample: CPUSample?
        public var memory: Double?
        public var memoryTotalGB: Double?
        public var load: Double?
        public var cores: Int?
        public var cpuTemperature: Double?
        public var gpuName: String?
        public var gpu: Double?
        public var gpuTemperature: Double?
        public var gpuPowerW: Double?

        /// The GPU's own temperature when there is one (what nvidia-smi reports); otherwise
        /// the hottest board sensor, which on GB10 runs well above the GPU.
        public var temperature: Double? { gpuTemperature ?? cpuTemperature }
    }

    public static func parse(_ output: String) -> Reading {
        var r = Reading()
        var memTotal: Double?, memAvail: Double?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("@"), let space = line.firstIndex(of: " ") else { continue }
            let tag = line[line.index(after: line.startIndex)..<space]
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            switch tag {
            case "stat":
                // cpu user nice system idle iowait irq softirq steal …
                let n = value.split(separator: " ").dropFirst().compactMap { UInt64($0) }
                guard n.count >= 4 else { continue }
                let idle = n[3] + (n.count > 4 ? n[4] : 0)
                let total = n.prefix(8).reduce(0, +)
                r.cpuSample = CPUSample(busy: total - idle, total: total)
            case "memtotal": memTotal = Double(value)
            case "memavail": memAvail = Double(value)
            case "load": r.load = Double(value)
            case "ncpu": r.cores = Int(value)
            case "ctemp":
                // Thermal zones report millidegrees.
                if let milli = Double(value), milli > 0 { r.cpuTemperature = milli > 1000 ? milli / 1000 : milli }
            case "gpu":
                let f = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard f.count >= 4 else { continue }
                r.gpuName = f[0]
                r.gpu = Double(f[1]).map { $0 / 100 }
                r.gpuTemperature = Double(f[2])
                r.gpuPowerW = Double(f[3])
            default:
                break
            }
        }
        if let memTotal, let memAvail, memTotal > 0 {
            r.memory = 1 - memAvail / memTotal
            r.memoryTotalGB = memTotal / 1_048_576
        }
        return r
    }

    /// Hosts from `~/.ssh/config` worth offering (no wildcards).
    public static func configuredHosts(in config: String) -> [String] {
        var hosts: [String] = []
        for line in config.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.first?.lowercased() == "host" else { continue }
            for name in parts.dropFirst() where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                let host = String(name)
                if MachineConfig.isValidHost(host), !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }
}
