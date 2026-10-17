import Foundation
import Observation
import TesseraKit

/// Follows a LLooM head's schedule: who holds which shared hardware (the Fleet band) and the jobs
/// agents report (tiles on the board). The head's address is saved with the app's state; its admin
/// key lives in the Keychain and is only ever sent to that address.
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

    @ObservationIgnored public private(set) var board: LLoomSchedule.Board?
    @ObservationIgnored private let store: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

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
        config = Config(url: base.absoluteString)
        StateFile.save(config, to: store)
        if let key, !key.isEmpty { Keychain.set(key, account: Self.account) }
        retryAt = .distantPast
        status = .loading
        poll()
        return true
    }

    /// Stops following the head and forgets its key; its jobs leave the board.
    public func disconnect() {
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
        guard let config, let base = LLoomSchedule.baseURL(config.url), !inFlight, Date() >= retryAt else { return }
        inFlight = true
        if board == nil, status == .off { status = .loading }
        let account = Self.account
        Task { [session] in
            defer { self.inFlight = false }
            // Reading a secret can raise a Keychain prompt; keep it off the main thread.
            let key = await Task.detached(priority: .utility) { Keychain.get(account: account) }.value
            do {
                let (data, response) = try await session.data(for: LLoomSchedule.request(base: base, token: key))
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard self.config == config else { return }  // reconfigured while asking
                guard (200..<300).contains(code) else {
                    throw Failure(code == 401 || code == 403 ? "The head refused the key (HTTP \(code))" : "The head answered HTTP \(code)")
                }
                self.apply(try LLoomSchedule.parse(data))
            } catch {
                guard self.config == config else { return }
                // Keep showing the last schedule, and ask less often until the head is back.
                self.retryAt = Date().addingTimeInterval(30)
                let message = (error as? Failure)?.message ?? error.localizedDescription
                if self.status != .failed(message) { self.status = .failed(message) }
            }
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Writes only what changed, so an unchanged poll re-renders nothing (the tiles' own writes are
    /// diffed by `AgentAppWatcher`; ages in their text move on with every poll).
    private func apply(_ next: LLoomSchedule.Board) {
        board = next
        updatedAt = Date()
        if status != .ok { status = .ok }
        let nextLanes = LLoomSchedule.lanes(next)
        if lanes != nextLanes { lanes = nextLanes }
        onChange?()
    }
}
