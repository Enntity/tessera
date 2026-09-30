import Darwin
import Foundation
import IOKit
import Observation
import TesseraKit

/// Vitals for this Mac and any SSH hosts the user adds (e.g. DGX Sparks), refreshed every few seconds.
@Observable
@MainActor
public final class MachineMonitor {
    public private(set) var remotes: [MachineConfig] = []
    public private(set) var vitals: [String: MachineVitals] = [:]

    public static let localId = "local"
    public var ordered: [MachineVitals] {
        ([Self.localId] + remotes.map(\.id)).compactMap { vitals[$0] }
    }

    @ObservationIgnored private let store: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let local = LocalSampler()
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastCPU: [String: RemoteVitals.CPUSample] = [:]
    @ObservationIgnored private var tick = 0

    public init(directory: URL) {
        store = directory.appendingPathComponent("machines.json")
        remotes = (StateFile.loadList(MachineConfig.self, from: store) ?? []).filter { $0.sshHost.map(MachineConfig.isValidHost) ?? false }
        vitals[Self.localId] = MachineVitals(id: Self.localId, name: Host.current().localizedName ?? "This Mac", isLocal: true)
        for r in remotes { vitals[r.id] = MachineVitals(id: r.id, name: r.name, isLocal: false) }
    }

    public func start() {
        poll()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func add(host: String, name: String?) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard MachineConfig.isValidHost(host), !remotes.contains(where: { $0.sshHost == host }) else { return }
        let clean = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let config = MachineConfig(name: clean.isEmpty ? host : clean, sshHost: host)
        remotes.append(config)
        vitals[config.id] = MachineVitals(id: config.id, name: config.name, isLocal: false)
        save()
        pollRemote(config)
    }

    public func remove(id: String) {
        remotes.removeAll { $0.id == id }
        vitals[id] = nil
        lastCPU[id] = nil
        save()
    }

    public func config(_ id: String) -> MachineConfig? { remotes.first { $0.id == id } }

    /// Named hosts from ~/.ssh/config, offered for one-click adding.
    public nonisolated static func suggestedHosts() -> [String] {
        let path = NSHomeDirectory() + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return RemoteVitals.configuredHosts(in: text)
    }

    private func save() {
        StateFile.save(remotes, to: store)
    }

    private func poll() {
        tick += 1
        let sample = local.sample()
        if var v = vitals[Self.localId] {
            v.status = .ok
            v.record(cpu: sample.cpu, gpu: sample.gpu)
            v.memory = sample.memory
            v.memoryTotalGB = sample.memoryTotalGB
            v.temperature = sample.temperature
            v.cores = ProcessInfo.processInfo.activeProcessorCount
            v.gpuName = "Apple GPU"
            vitals[Self.localId] = v
        }
        // Remotes every other tick (4 s): cheap for the hosts, fresh enough for a glance.
        if tick % 2 == 1 { for r in remotes { pollRemote(r) } }
    }

    private func pollRemote(_ config: MachineConfig) {
        guard let host = config.sshHost, !inFlight.contains(config.id) else { return }
        inFlight.insert(config.id)
        DispatchQueue.global(qos: .utility).async {
            let result = SSHProbe.run(host: host, command: RemoteVitals.script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(result, to: config) }
            }
        }
    }

    private func apply(_ result: Result<String, SSHProbe.Failure>, to config: MachineConfig) {
        inFlight.remove(config.id)
        guard var v = vitals[config.id] else { return }  // removed meanwhile
        switch result {
        case .success(let output):
            let r = RemoteVitals.parse(output)
            v.status = .ok
            v.message = nil
            v.record(cpu: r.cpuSample?.utilization(since: lastCPU[config.id]), gpu: r.gpu)
            if let sample = r.cpuSample { lastCPU[config.id] = sample }
            v.memory = r.memory
            v.memoryTotalGB = r.memoryTotalGB
            v.temperature = r.temperature
            v.hottestSensor = r.gpuTemperature != nil ? r.cpuTemperature : nil
            v.gpuName = r.gpuName
            v.gpuPowerW = r.gpuPowerW
            v.load = r.load
            v.cores = r.cores
        case .failure(let failure):
            v.status = .unreachable
            v.message = failure.message
            lastCPU[config.id] = nil
        }
        vitals[config.id] = v
    }
}

/// Runs one command on a host with the user's own ssh setup. Key-based only (never prompts), and a
/// shared control connection so polling costs one handshake per host, not one per sample.
enum SSHProbe {
    struct Failure: Error { let message: String }

    static func run(host: String, command: String, timeout: TimeInterval = 8) -> Result<String, Failure> {
        guard MachineConfig.isValidHost(host) else { return .failure(Failure(message: "Invalid host")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10",
                       "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/tessera-%C", "-o", "ControlPersist=120",
                       "--", host, command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(Failure(message: error.localizedDescription)) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "ssh exited \(p.terminationStatus)"
            return .failure(Failure(message: msg.preview(90)))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }
}

/// This Mac's CPU, GPU, memory and hottest SoC die temperature.
final class LocalSampler {
    struct Sample {
        var cpu: Double?
        var gpu: Double?
        var memory: Double?
        var memoryTotalGB: Double
        var temperature: Double?
    }

    private var previous: host_cpu_load_info?
    private let thermal = ThermalSensors()

    func sample() -> Sample {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return Sample(cpu: cpu(), gpu: Self.gpuUtilization(), memory: memory(total: total),
                      memoryTotalGB: total / 1_073_741_824, temperature: thermal.hottestDie())
    }

    private func cpu() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        defer { previous = load }
        guard let prev = previous else { return nil }
        let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
        let sys = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
        let sum = user + sys + idle + nice
        return sum > 0 ? (user + sys + nice) / sum : nil
    }

    private func memory(total: Double) -> Double? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS, total > 0 else { return nil }
        return Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * Double(vm_kernel_page_size) / total
    }

    /// Apple GPU busy percentage, published by the accelerator driver.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util / 100)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }
}

/// Apple Silicon temperature sensors via IOHIDEventSystemClient. It's SPI, so everything is looked up
/// at runtime and simply yields nil if unavailable.
final class ThermalSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    /// The services belong to the client; it must outlive them or reads touch freed memory.
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var copyEvent: CopyEventFn?
    private var floatValue: FloatValueFn?

    private static let temperatureEvent: Int64 = 15

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"), let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"), let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue"), let p = dlsym(h, "IOHIDServiceClientCopyProperty") else { return }
        let create = unsafeBitCast(c, to: CreateFn.self)
        let setMatching = unsafeBitCast(m, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(s, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(p, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(e, to: CopyEventFn.self)
        floatValue = unsafeBitCast(f, to: FloatValueFn.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Vendor page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // Die sensors describe the SoC; fall back to everything except calibration entries.
        let named = all.map { ($0, (copyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? "") }
        let dies = named.filter { $0.1.contains("tdie") }.map(\.0)
        services = dies.isEmpty ? named.filter { !$0.1.contains("tcal") }.map(\.0) : dies
    }

    func hottestDie() -> Double? {
        guard let copyEvent, let floatValue else { return nil }
        let field = Int32(Self.temperatureEvent << 16)
        let values = services.compactMap { svc -> Double? in
            guard let event = copyEvent(svc, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = floatValue(event, field)
            return v > 0 && v < 150 ? v : nil
        }
        return values.max()
    }
}
