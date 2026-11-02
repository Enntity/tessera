import Foundation
import Observation
import TesseraKit

/// Native fleet presentation. Accord owns manager connections and telemetry transport;
/// LLooM supplies model effects; migrated resources and jobs are owned by Accord.
@Observable
@MainActor
public final class FleetService {
    public struct Config: Codable, Equatable, Sendable {
        public var url: String
    }

    public enum Status: Equatable, Sendable {
        case off, loading, ok
        case failed(String)
    }

    public private(set) var config: Config?
    public private(set) var lanes: [LLoomSchedule.Lane] = []
    public private(set) var status: Status = .off
    /// When the head last answered.
    public private(set) var updatedAt: Date?
    /// Called when the jobs or leases the board shows may have changed.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Whether every reported job becomes a tile. Off, only what wants the user does (a failed or
    /// stalled job, a lease running out): the rest stay on the head and in the Fleet band.
    public var showJobs = Preferences.store.bool(forKey: "tessera.fleetJobTiles") {
        didSet {
            Preferences.store.set(showJobs, forKey: "tessera.fleetJobTiles")
            onChange?()
        }
    }

    @ObservationIgnored public private(set) var board: LLoomSchedule.Board?
    @ObservationIgnored private let store: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored public var accord: AccordBridge?
    @ObservationIgnored private var managerInitialized = false
    @ObservationIgnored private var newConfiguration = false

    public var isVisible = !Preferences.store.bool(forKey:"tessera.hideAccordFleet") {
        didSet {
            Preferences.store.set(!isVisible,forKey:"tessera.hideAccordFleet")
            if isVisible { poll() } else { board = nil; lanes = []; status = .off; updatedAt = nil; onChange?() }
        }
    }

    static let account = "lloom.head"
    public static let refreshInterval: TimeInterval = 10

    public init(directory: URL) {
        store = directory.appendingPathComponent("lloom.json")
        config = StateFile.load(Config.self, from: store).flatMap { LLoomSchedule.baseURL($0.url) == nil ? nil : $0 }
    }

    public func start() {
        poll()
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public var hasKey: Bool { Keychain.contains(account: Self.account) }

    /// Follows the head at `url`; a non-empty `key` replaces the saved one. False for an address
    /// Tessera won't use.
    @discardableResult
    public func connect(url: String, key: String?) -> Bool {
        guard let base = LLoomSchedule.baseURL(url) else { return false }
        isVisible = true
        config = Config(url: base.absoluteString)
        StateFile.save(config, to: store)
        if let key, !key.isEmpty { Keychain.set(key, account: Self.account) }
        retryAt = .distantPast
        managerInitialized = false
        newConfiguration = true
        status = .loading
        poll()
        return true
    }

    /// Hides this native view; never deletes a shared manager or changes its ownership.
    public func disconnect() {
        isVisible = false
        config = nil
        try? FileManager.default.removeItem(at: store)
        Keychain.set(nil, account: Self.account)
        board = nil
        lanes = []
        status = .off
        updatedAt = nil
        onChange?()
    }

    /// The jobs and leases to show as tiles: running ones, and those that ended within `lookback`.
    public func items(lookback: TimeInterval) -> [LLoomSchedule.Item] {
        board.map { LLoomSchedule.items($0, lookback: lookback) } ?? []
    }

    /// A job or lease as an app-session tile, so it joins the board, the Needs-you lane, alerts and
    /// the phone like any conversation. Its notes read as its transcript.
    public nonisolated static func session(_ item: LLoomSchedule.Item) -> AgentAppSession {
        AgentAppSession(id: item.id, flavor: .lloom, title: item.title, cwd: item.subtitle, openURL: nil, resumeCommand: nil,
                        snapshot: ConversationSnapshot(items: item.notes, activity: item.activity, detail: item.detail,
                                                       lastEventAt: item.changedAt),
                        summary: nil, lastActivityAt: item.lastActivityAt, progress: item.progress, link: item.session)
    }

    private func poll() {
        guard isVisible, let accord, !inFlight, Date() >= retryAt else { return }
        inFlight = true
        if board == nil, status == .off { status = .loading }
        let config = self.config, account = Self.account
        Task {
            defer { self.inFlight = false }
            do {
                if let config, !managerInitialized {
                    let key = await Task.detached { Keychain.get(account: account) }.value
                    var args: [String:Any] = ["name":"lloom","type":"lloom","url":config.url,"ifAbsent":!newConfiguration]
                    if let key { args["key"] = key }
                    _ = try await accord.request("manager-configure", args:args)
                    guard self.config == config else { return }
                    managerInitialized = true; newConfiguration = false
                }
                let schedules = try await accord.request("manager-schedules")
                let managers = schedules["managers"] as? [[String:Any]] ?? []
                guard Self.managersReachable(managers) else { throw Failure("Accord reports an unreachable resource manager; ownership is unknown") }
                let hosts = try await accord.request("hosts")
                let fleet = try await Self.nativeFleet(hosts: hosts["hosts"] as? [[String:Any]] ?? []) { operation, host in
                    try await accord.request(operation, host:host)
                }
                guard self.isVisible else { return }
                self.apply(try Self.project(resources:fleet.resources, jobs:fleet.jobs, managers:managers))
            } catch {
                guard self.isVisible else { return }
                self.retryAt = Date().addingTimeInterval(10)
                let message = (error as? Failure)?.message ?? error.localizedDescription
                if self.status != .failed(message) { self.status = .failed(message) }
            }
        }
    }

    static func managersReachable(_ managers: [[String:Any]]) -> Bool {
        managers.allSatisfy { ["observed", "migrated"].contains($0["state"] as? String ?? "") }
    }

    /// Read each authority directly, including migrated managers' native resources.
    /// A failed host preserves the last board rather than presenting its assets as free.
    static func nativeFleet(hosts: [[String:Any]], fetch: (String, String) async throws -> [String:Any]) async throws -> (resources: [[String:Any]], jobs: [[String:Any]]) {
        var resources: [[String:Any]] = [], jobs: [[String:Any]] = []
        var seen = Set<String>()
        for host in hosts {
            guard let authority = host["authority"] as? String, seen.insert(authority).inserted else { continue }
            let r = try await fetch("resources", authority)
            let j = try await fetch("jobs", authority)
            resources += (r["resources"] as? [[String:Any]] ?? []).filter { $0["manager"] == nil }
            jobs += (j["jobs"] as? [[String:Any]] ?? []).map { job in
                var item = job
                if let id = job["id"] as? String { item["id"] = authority + "/" + id }
                return item
            }
        }
        return (resources, jobs)
    }

    /// A view projection, never a second scheduler. Preserve every delegated job/lease field.
    static func project(resources: [[String:Any]], jobs: [[String:Any]], managers: [[String:Any]]) throws -> LLoomSchedule.Board {
        var rs: [[String:Any]] = [], leases: [[String:Any]] = [], js: [[String:Any]] = []
        for manager in managers {
            guard let name = manager["name"] as? String, let board = manager["board"] as? [String:Any] else { continue }
            let prefix = name + ":"
            for var r in board["resources"] as? [[String:Any]] ?? [] {
                r["id"] = prefix + (r["id"] as? String ?? "unknown")
                r["holders"] = (r["holders"] as? [String] ?? []).map { prefix + $0 }
                r["queue"] = (r["queue"] as? [String] ?? []).map { prefix + $0 }; rs.append(r)
            }
            for var r in board["reservations"] as? [[String:Any]] ?? [] {
                r["id"] = prefix + (r["id"] as? String ?? "unknown")
                r["resource"] = prefix + (r["resource"] as? String ?? "unknown"); leases.append(r)
            }
            for var j in board["jobs"] as? [[String:Any]] ?? [] {
                j["id"] = prefix + (j["id"] as? String ?? "unknown")
                if let r = j["resource"] as? String { j["resource"] = prefix + r }; js.append(j)
            }
        }
        for r in resources where r["manager"] == nil && r["plugin"] as? String != "artifact" {
            guard let id = r["id"] as? String else { continue }
            let holder = r["holder"] as? [String:Any]
            let claim = holder?["claim"] as? String
            var view: [String:Any] = ["id":id, "label":r["label"] ?? id, "description":r["label"] ?? id, "hosts":r["hosts"] ?? [],"holders":claim.map { [$0] } ?? [],"queue":(r["queue"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String },"capacity":1]
            if r["state"] as? String == "unknown" { view["error"] = "Controller unavailable; ownership unknown" }
            rs.append(view)
            if let holder, let claim {
                let state = ["running":"active", "preparing":"acquiring", "releasing":"releasing",
                             "revoking":"recovering", "recovering":"recovering", "stuck":"stuck", "failed":"stuck"][holder["state"] as? String ?? ""] ?? "unknown"
                var lease: [String:Any] = ["id":claim, "resource":id, "owner":holder["label"] ?? holder["actor"] ?? "unknown",
                    "state":state, "expiresAt":holder["deadline"] ?? NSNull()]
                for field in ["startedAt", "updatedAt", "warnedAt", "error", "purpose"] {
                    if let value = holder[field] { lease[field] = value }
                }
                if let address = holder["address"] as? String { lease["session"] = "accord:" + address }
                if state == "unknown" { rs[rs.count - 1]["error"] = "Lease status unavailable; resource remains held" }
                leases.append(lease)
            }
        }
        for j in jobs {
            guard let id = j["id"] as? String else { continue }
            let state = j["state"] as? String ?? "unknown"
            let metrics = (j["metrics"] as? [String:Any] ?? [:]).filter { $0.value is String || $0.value is NSNumber }
            var item: [String:Any] = ["id":"accord:"+id,"title":j["title"] ?? "Job","owner":j["actor"] ?? "agent",
                "state":state == "working" ? "running" : state,"startedAt":j["created_at"] ?? 0,"heartbeatAt":j["updated_at"] ?? 0,
                "note":j["note"] ?? "","notes":[],"metrics":metrics]
            if let progress = j["progress"] as? [String:Any], progress["done"] is NSNumber { item["progress"] = progress }
            if j["stalled"] as? Bool == true { item["stalledAt"] = j["updated_at"] }
            js.append(item)
        }
        return try LLoomSchedule.parse(JSONSerialization.data(withJSONObject:["now":Date().timeIntervalSince1970*1000,"resources":rs,"reservations":leases,"jobs":js]))
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Writes only what changed, so an unchanged poll re-renders nothing (the tiles' own writes are
    /// diffed by `AgentAppWatcher`; ages in their text move on with every poll).
    func apply(_ next: LLoomSchedule.Board) {
        board = next
        updatedAt = Date()
        if status != .ok { status = .ok }
        let nextLanes = LLoomSchedule.lanes(next)
        if lanes != nextLanes { lanes = nextLanes }
        onChange?()
    }
}
