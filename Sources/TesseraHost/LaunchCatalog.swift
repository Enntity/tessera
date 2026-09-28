import Darwin
import Foundation
import Observation
import TesseraKit

public enum LaunchCatalog {
    public static let known: [LaunchPreset] = [
        LaunchPreset(name: "Shell", command: nil, flavor: .shell),
        LaunchPreset(name: "Claude Code", command: "claude", flavor: .claude),
        LaunchPreset(name: "Codex", command: "codex", flavor: .codex),
        LaunchPreset(name: "Grok", command: "grok", flavor: .grok),
        LaunchPreset(name: "Gemini", command: "gemini", flavor: .gemini),
        LaunchPreset(name: "omp", command: "omp", flavor: .omp),
        LaunchPreset(name: "opencode", command: "opencode", flavor: .opencode),
        LaunchPreset(name: "aider", command: "aider", flavor: .aider)
    ]

    /// Which agent CLIs are on the user's login-shell PATH. Runs a shell, so call off the main thread.
    public static func detectInstalled() -> [LaunchPreset] {
        let names = known.compactMap(\.command)
        let script = names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return known }
        p.waitUntilExit()
        let found = Set(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
        return known.filter { $0.command == nil || found.contains($0.command!) }
    }
}

/// Machine vitals for the HUD.
@Observable
@MainActor
public final class SystemStats {
    public private(set) var cpu: Double = 0
    public private(set) var memoryUsed: Double = 0
    public private(set) var memoryTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    public private(set) var cpuHistory: [Double] = []

    @ObservationIgnored private var previous: host_cpu_load_info?
    @ObservationIgnored private var timer: Timer?

    public init() {}

    public func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if ok == KERN_SUCCESS {
            if let prev = previous {
                let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
                let sys = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
                let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
                let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
                let total = user + sys + idle + nice
                cpu = total > 0 ? (user + sys + nice) / total : 0
                cpuHistory.append(cpu)
                if cpuHistory.count > 40 { cpuHistory.removeFirst() }
            }
            previous = load
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmOk = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmOk == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * page
            memoryUsed = used / Double(ProcessInfo.processInfo.physicalMemory)
        }
    }
}
