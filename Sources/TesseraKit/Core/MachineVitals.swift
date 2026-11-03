import Foundation

/// A machine the board watches: this Mac, or a Linux host reached over SSH.
public struct MachineConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// An SSH destination as typed at a shell (`gpu-box-1`, `me@10.0.0.4`). Nil for this Mac.
    public var sshHost: String?
    public var authority: String?

    public init(id: String = UUID().uuidString, name: String, sshHost: String?, authority: String? = nil) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.authority = authority
    }

    /// Host strings go to `ssh` as an argument, never through a shell; still refuse anything that
    /// could read as an option or carry odd characters.
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count <= 255
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._@-:[]".contains($0)) }
    }

    /// The machine an `ssh …` command line connects to (`ssh -p 2222 me@gpu-box` → `gpu-box`), so a
    /// tile running one can say where it is. Nil for any other command.
    public static func sshHost(in command: String) -> String? {
        guard let invocation = SessionResume.Invocation(command), invocation.name == "ssh" else { return nil }
        // Options that take a value: the rest of their word, or when they end it, the next word.
        let valued = Set("BbcDEeFIiJLlmOopQRSWw")
        var words = invocation.words.dropFirst()
        while let word = words.first, word.hasPrefix("-"), word != "--" {
            words.removeFirst()
            if let option = word.dropFirst().firstIndex(where: valued.contains), word.index(after: option) == word.endIndex {
                words = words.dropFirst()
            }
        }
        if words.first == "--" { words.removeFirst() }
        guard var host = words.first else { return nil }
        if host.hasPrefix("ssh://") {
            host = String(host.dropFirst(6).prefix { $0 != "/" })
            // (A bracketed IPv6 address keeps its colons.)
            if !host.hasSuffix("]"), let port = host.lastIndex(of: ":") { host = String(host[..<port]) }
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        return isValidHost(host) ? host : nil
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
    /// How busy the machine is at a glance: its GPU (what agents and models load) when there is one
    /// to read, else its CPU.
    public var primaryLoad: (name: String, value: Double)? {
        if let gpu { return ("GPU", gpu) }
        return cpu.map { ("CPU", $0) }
    }

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

/// Native picker suggestions; host connections and sampling belong to Accord.
public enum SSHHostSuggestions {
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
