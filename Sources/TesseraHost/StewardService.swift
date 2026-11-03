import Foundation
import Observation
import TesseraKit

/// Native board brief and presentation suggestions. Shared per-session summaries are
/// consumed from Accord, which alone schedules and stores that analysis.
@Observable
@MainActor
public final class StewardService {
    public struct Config: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// The OpenAI-compatible base URL, ending in /v1.
        public var url: String
        public var model: String

        public init(enabled: Bool = false, url: String = "", model: String = "tessera") {
            self.enabled = enabled
            self.url = url
            self.model = model
        }
    }

    public enum Status: Equatable, Sendable {
        case off, idle, thinking
        case failed(String)
    }

    public private(set) var config: Config
    public private(set) var status: Status = .off
    public private(set) var brief: Steward.Brief?
    /// One line per tile, by tile id.
    public private(set) var summaries: [String: Steward.TileSummary] = [:]
    /// Suggestions the user waved off; not offered again until the tile changes.
    public private(set) var dismissed: Set<String> = []

    /// The board as the steward reads it, and what changed since the user last looked.
    @ObservationIgnored public var digests: (() -> [Steward.Digest])?
    @ObservationIgnored public var sharedSummaries: (() -> [String: Steward.TileSummary])?
    @ObservationIgnored public var configureShared: ((Config, String?, Bool) async throws -> Void)?
    @ObservationIgnored public var changes: (() -> [String])?
    /// Privacy mode is on: nothing is read or sent.
    @ObservationIgnored public var paused: (() -> Bool)?

    @ObservationIgnored private let store: URL
    @ObservationIgnored private let feedback: URL
    @ObservationIgnored private var timer: Timer?
    /// Each tile's fingerprint when first seen like this, and when it was last summarized.
    @ObservationIgnored private var seen: [String: (fingerprint: Int, since: Date)] = [:]
    @ObservationIgnored private var briefing = false
    @ObservationIgnored private var briefedState: Int?
    @ObservationIgnored private var lastBriefAt = Date.distantPast
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let readKey: @Sendable () -> String?

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }

    nonisolated static let account = "steward.key"
    /// Native board brief cadence; Accord schedules individual session summaries.
    static let briefEvery: TimeInterval = 60

    public init(directory: URL) {
        self.session = Self.makeSession()
        self.readKey = { Keychain.get(account: Self.account) }
        store = directory.appendingPathComponent("steward.json")
        feedback = directory.appendingPathComponent("steward-feedback.ndjson")
        config = StateFile.load(Config.self, from: store) ?? Config()
    }

    init(directory: URL, session: URLSession, readKey: @escaping @Sendable () -> String?) {
        self.session = session
        self.readKey = readKey
        store = directory.appendingPathComponent("steward.json")
        feedback = directory.appendingPathComponent("steward-feedback.ndjson")
        config = StateFile.load(Config.self, from: store) ?? Config()
    }

    public var hasKey: Bool { Keychain.contains(account: Self.account) }

    public func start() {
        if config.enabled {
            status = .idle
            let current = config
            Task {
                let key = await Task.detached { Keychain.get(account: Self.account) }.value
                do { try await configureShared?(current,key,true) }
                catch { status = .failed("Accord summary setup: " + error.localizedDescription) }
            }
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Saves the settings; a non-empty `key` replaces the saved one. False for an unusable address.
    @discardableResult
    public func configure(_ next: Config, key: String?) -> Bool {
        guard !next.enabled || (Self.baseURL(next.url) != nil && !next.model.isEmpty) else { return false }
        generation = UUID()
        brief = nil
        summaries = [:]
        lastBriefAt = .distantPast
        config = next
        StateFile.save(config, to: store)
        if let key, !key.isEmpty { Keychain.set(key, account: Self.account) }
        if !next.enabled {
            status = .off
            brief = nil
            summaries = [:]
        } else {
            status = .idle
            retryAt = .distantPast
            briefedState = nil
            tick()
        }
        if next.enabled {
            Task {
                do { try await configureShared?(next,key,false) }
                catch { status = .failed("Accord summary setup: " + error.localizedDescription) }
            }
        }
        return true
    }

    public static func baseURL(_ raw: String) -> URL? {
        LLoomSchedule.baseURL(raw)
    }

    /// Rebuild the brief now (the user asked).
    public func refresh() {
        briefedState = nil
        lastBriefAt = .distantPast
        retryAt = .distantPast
        tick()
    }

    /// The user waved a suggestion off (or acted on it): it is noted, to tune what is suggested.
    public func record(_ action: String, tile: String, why: String) {
        dismissed.insert(tile)
        let line = (try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "action": action,
                                                                 "tile": tile, "why": why])) ?? Data()
        if let handle = try? FileHandle(forWritingTo: feedback) {
            handle.seekToEndOfFile()
            handle.write(line + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: feedback)
        }
    }

    // MARK: The loop

    private func tick() {
        guard paused?() != true, let digests = digests?() else { return }
        let shared = sharedSummaries?() ?? [:]
        if summaries != shared { summaries = shared }
        let ids = Set(digests.map(\.id))
        for id in seen.keys where !ids.contains(id) { seen[id] = nil }
        for d in digests where seen[d.id]?.fingerprint != d.fingerprint {
            seen[d.id] = (d.fingerprint, Date()); dismissed.remove(d.id)
        }
        guard config.enabled, let base = Self.baseURL(config.url), Date() >= retryAt else { return }
        let now = Date()
        let boardState = digests.map { "\($0.id)\($0.state)\($0.waiting)\(shared[$0.id]?.summary ?? "")" }.joined().hashValue
        // The brief must not wait for tile summaries to drain: on a busy board there is always
        // another tile to summarize, and the brief would starve. It runs on its own request.
        if !briefing, briefedState != boardState, now.timeIntervalSince(lastBriefAt) >= Self.briefEvery || brief == nil {
            makeBrief(digests.map { var d = $0; d.summary = shared[d.id]?.summary; return d }, state: boardState, base: base)
        }
    }

    private func makeBrief(_ digests: [Steward.Digest], state: Int, base: URL) {
        briefing = true
        status = .thinking
        let changes = self.changes?() ?? []
        call(base: base, messages: Steward.briefMessages(digests, changes: changes), maxTokens: 600) { [weak self] data in
            guard let self else { return }
            self.briefing = false
            self.lastBriefAt = Date()
            guard let data else { return }
            do {
                let next = try Steward.brief(fromCompletion: data, digests: digests, changes: changes)
                self.brief = next
                self.briefedState = state
                if self.status != .idle { self.status = .idle }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// One chat completion; `done` gets the body, or nil after a failure (which is shown, and
    /// backs off for a minute).
    private func call(base: URL, messages: [[String: String]], maxTokens: Int, done: @escaping @MainActor (Data?) -> Void) {
        let model = config.model
        let generation = self.generation
        Task { [session, readKey] in
            let key = await Task.detached(priority: .utility) { readKey() }.value
            guard self.acceptsResponse(generation: generation) else { done(nil); return }
            do {
                let request = try Steward.request(base: base, key: key, model: model, messages: messages, maxTokens: maxTokens)
                let (data, response) = try await session.data(for: request)
                guard self.acceptsResponse(generation: generation) else { done(nil); return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw Steward.Failure.unreadable(code == 401 || code == 403 ? "the endpoint refused the key (HTTP \(code))" : "HTTP \(code)")
                }
                // The endpoint answers again: an earlier failure no longer stands.
                if case .failed = self.status { self.status = .idle }
                done(data)
            } catch {
                guard self.acceptsResponse(generation: generation) else { done(nil); return }
                self.retryAt = Date().addingTimeInterval(60)
                self.status = .failed(error.localizedDescription)
                done(nil)
            }
        }
    }

    private func acceptsResponse(generation: UUID) -> Bool {
        self.generation == generation && config.enabled && paused?() != true
    }
}
