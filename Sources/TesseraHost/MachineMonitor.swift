import Foundation
import Observation
import TesseraKit

/// Presentation of Accord's cached host telemetry. Collection, SSH transport and sensor
/// lifetime belong to the host daemon; no Tessera-owned probes or hardware polling remain.
@Observable @MainActor
public final class MachineMonitor {
    public private(set) var remotes: [MachineConfig] = []
    public private(set) var vitals: [String: MachineVitals] = [:]
    public private(set) var faces: [String: MachineVitals] = [:]
    public static let localId = "local"
    public var ids: [String] { [Self.localId] + remotes.map(\.id) }
    public var ordered: [MachineVitals] { ids.compactMap { vitals[$0] } }
    @ObservationIgnored public var accord: AccordBridge?
    @ObservationIgnored private let store: URL
    @ObservationIgnored private let hiddenStore: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var pinned: Set<String> = []
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var connecting: Set<String> = []
    @ObservationIgnored private var lastConnect: [String: Date] = [:]

    public init(directory: URL) {
        store = directory.appendingPathComponent("machines.json")
        hiddenStore = directory.appendingPathComponent("hidden-machines.json")
        hidden = Set(StateFile.loadList(String.self, from:hiddenStore) ?? [])
        remotes = StateFile.loadList(MachineConfig.self, from: store) ?? []
        publish(MachineVitals(id: Self.localId, name: Host.current().localizedName ?? "This Mac", isLocal: true))
        for r in remotes { publish(MachineVitals(id:r.id, name:r.name, isLocal:false)) }
    }
    public func start() {
        for config in remotes { connect(config) }
        Task { await refresh() }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        self.timer = timer
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
    }
    public func add(host: String, name: String?) {
        guard MachineConfig.isValidHost(host), !remotes.contains(where: { $0.sshHost == host }) else { return }
        let config = MachineConfig(name: name?.isEmpty == false ? name! : host, sshHost: host)
        remotes.append(config)
        StateFile.save(remotes, to: store)
        var v = MachineVitals(id:config.id, name:config.name, isLocal:false, status:.unreachable)
        v.message = "Connecting through Accord…"
        publish(v)
        connect(config)
    }
    private func connect(_ config: MachineConfig) {
        guard let accord, let host = config.sshHost, !connecting.contains(config.id),
              Date().timeIntervalSince(lastConnect[config.id] ?? .distantPast) >= 30 else { return }
        connecting.insert(config.id)
        lastConnect[config.id] = Date()
        Task {
            defer { connecting.remove(config.id) }
            do {
                let authority = try await accord.connectHost(host)
                guard let index = remotes.firstIndex(where: { $0.id == config.id }) else { return }
                hidden.remove(authority)
                StateFile.save(Array(hidden),to:hiddenStore)
                remotes[index].authority = authority
                // Discovery can beat SSH alias resolution. Keep the user's existing chip,
                // rather than a second auto-discovered chip for the same machine.
                let duplicates = remotes.filter { $0.id != config.id && $0.authority == authority && $0.sshHost == nil }
                remotes.removeAll { item in duplicates.contains { $0.id == item.id } }
                for item in duplicates { vitals[item.id] = nil; faces[item.id] = nil }
                StateFile.save(remotes, to:store)
                await refresh()
            } catch {
                var v = MachineVitals(id:config.id,name:config.name,isLocal:false,status:.unreachable)
                v.message = "Accord connection unavailable. Check the host's Accord service; retrying automatically."
                publish(v)
            }
        }
    }
    public func remove(id: String) {
        hidden.insert(id)
        if let authority = remotes.first(where:{ $0.id == id })?.authority { hidden.insert(authority) }
        StateFile.save(Array(hidden),to:hiddenStore)
        remotes.removeAll { $0.id == id }
        vitals[id] = nil; faces[id] = nil
        StateFile.save(remotes, to: store)
    }
    public func config(_ id: String) -> MachineConfig? { remotes.first { $0.id == id } }
    public var unwatchedHosts: [String] {
        let config = (try? String(contentsOfFile:NSHomeDirectory()+"/.ssh/config",encoding:.utf8)) ?? ""
        let known = Set(remotes.compactMap(\.sshHost))
        return SSHHostSuggestions.configuredHosts(in:config).filter { !known.contains($0) }
    }
    #if DEBUG
    public func pin(_ readings: [MachineVitals]) {
        for r in readings {
            if !ids.contains(r.id) { remotes.append(MachineConfig(id:r.id, name:r.name, sshHost:r.name)) }
            pinned.insert(r.id); publish(r)
        }
    }
    #endif
    public func refresh() async {
        guard !busy, let accord else { return }
        busy = true
        defer { busy = false }
        for config in remotes where vitals[config.id]?.status != .ok { connect(config) }
        do {
            let catalog = try await accord.request("hosts")
            let hosts = catalog["hosts"] as? [[String:Any]] ?? []
            // Independent requests keep an unreachable remote from blocking local readings.
            await withTaskGroup(of: Void.self) { group in
                for host in hosts {
                    guard let authority = host["authority"] as? String else { continue }
                    let local = host["local"] as? Bool == true
                    group.addTask { @MainActor in
                        do {
                            let sample = try await accord.request("telemetry", host: local ? nil : authority)
                            let hostname = sample["hostname"] as? String ?? authority
                            let existing = self.remotes.first { $0.id == authority || $0.authority == authority || $0.sshHost == hostname || $0.name == hostname }
                            let id = local ? Self.localId : existing?.id ?? authority
                            guard !self.hidden.contains(authority), !self.hidden.contains(id), !self.pinned.contains(id) else { return }
                            if !local && existing == nil {
                                guard self.connecting.isEmpty else { return }
                                self.remotes.append(MachineConfig(id:id, name:hostname, sshHost:nil, authority:authority)); StateFile.save(self.remotes,to:self.store)
                            }
                            self.publish(Self.project(sample, id:id, name:existing?.name ?? hostname, local:local))
                        } catch {
                            let id = local ? Self.localId : self.remotes.first(where: { $0.authority == authority })?.id ?? authority
                            guard !self.hidden.contains(authority), !self.hidden.contains(id), !self.pinned.contains(id) else { return }
                            if !local && !self.remotes.contains(where:{ $0.id == id }) { self.remotes.append(MachineConfig(id:id,name:authority,sshHost:nil,authority:authority)); StateFile.save(self.remotes,to:self.store) }
                            self.publish(MachineVitals(id:id, name:self.vitals[id]?.name ?? authority, isLocal:local, status:.unreachable))
                        }
                    }
                }
            }
        } catch {
            for id in ids where !pinned.contains(id) {
                var v = MachineVitals(id:id, name:vitals[id]?.name ?? id, isLocal:id == Self.localId, status:.unreachable)
                v.message = "Accord unavailable; readings unknown"
                publish(v)
            }
        }
    }
    static func project(_ sample: [String:Any], id: String, name: String, local: Bool) -> MachineVitals {
        var v = MachineVitals(id:id, name:name, isLocal:local)
        guard sample["stale"] as? Bool == false, let h = sample["host"] as? [String:Any] else {
            v.status = .unreachable; v.message = "Telemetry unavailable or stale"; return v
        }
        v.status = .ok
        let cpu = h["cpu"] as? [String:Any] ?? [:], gpu = h["gpu"] as? [String:Any] ?? [:]
        let memory = h["memory"] as? [String:Any] ?? [:], thermal = h["thermal"] as? [String:Any] ?? [:]
        func number(_ x: Any?) -> Double? { guard let n = x as? Double, n.isFinite else { return nil }; return n }
        func fraction(_ x: Any?) -> Double? { number(x).flatMap { (0...100).contains($0) ? $0 / 100 : nil } }
        v.cpu = fraction(cpu["utilization"]); v.gpu = fraction(gpu["utilization"])
        v.memory = fraction(memory["pressureUtilization"])
        v.memoryTotalGB = number(memory["totalBytes"]).map { $0 / 1073741824 }
        v.temperature = number(gpu["temperatureC"]) ?? number(thermal["hottestC"])
        v.hottestSensor = number(thermal["hottestC"])
        v.gpuName = (gpu["devices"] as? [[String:Any]])?.compactMap { $0["name"] as? String }.joined(separator:", ")
        v.gpuPowerW = number(gpu["powerDrawW"])
        v.load = (cpu["loadAverage"] as? [Double])?.first
        v.cores = cpu["logicalCpus"] as? Int
        return v
    }
    /// Stores a reading and the words it is shown in, each only when it would look different, so an
    /// unchanged poll re-renders nothing.
    private func publish(_ reading: MachineVitals) {
        var v = reading
        v.quantize()
        if vitals[v.id] != v { vitals[v.id] = v }
        if faces[v.id] != v.face { faces[v.id] = v.face }
    }

}
