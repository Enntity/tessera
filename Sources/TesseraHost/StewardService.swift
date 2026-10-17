import Foundation
import Observation
import TesseraKit

/// Tessera's steward: a model, reached through any OpenAI-compatible endpoint (a LLooM gateway by
/// default), that keeps a one-line summary of every tile and a short brief of the whole board, so
/// the user reads a few lines instead of every tile. It only reports and suggests.
///
/// A tile is summarized again only when what it shows has changed and settled; the brief is
/// rebuilt from those summaries when anything moved. Text goes out with credentials removed, and
/// nothing goes out in privacy mode.
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
    @ObservationIgnored public var changes: (() -> [String])?
    /// Privacy mode is on: nothing is read or sent.
    @ObservationIgnored public var paused: (() -> Bool)?

    @ObservationIgnored private let store: URL
    @ObservationIgnored private let feedback: URL
    @ObservationIgnored private var timer: Timer?
    /// Each tile's fingerprint when first seen like this, and when it was last summarized.
    @ObservationIgnored private var seen: [String: (fingerprint: Int, since: Date)] = [:]
    @ObservationIgnored private var summarized: [String: Int] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var briefing = false
    @ObservationIgnored private var briefedState: Int?
    @ObservationIgnored private var lastBriefAt = Date.distantPast
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()

    static let account = "steward.key"
    /// A tile must show the same thing this long before it is summarized (a busy terminal isn't
    /// summarized on every line it prints).
    static let settle: TimeInterval = 20
    static let briefEvery: TimeInterval = 60
    static let concurrency = 2

    public init(directory: URL) {
        store = directory.appendingPathComponent("steward.json")
        feedback = directory.appendingPathComponent("steward-feedback.ndjson")
        config = StateFile.load(Config.self, from: store) ?? Config()
    }

    public var hasKey: Bool { Keychain.contains(account: Self.account) }

    public func start() {
        if config.enabled { status = .idle }
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
        guard config.enabled, let base = Self.baseURL(config.url), Date() >= retryAt else { return }
        guard paused?() != true, let digests = digests?() else { return }
        let now = Date()
        let ids = Set(digests.map(\.id))
        for id in seen.keys where !ids.contains(id) { (seen[id], summarized[id], summaries[id]) = (nil, nil, nil) }
        for d in digests {
            let fp = d.fingerprint
            if seen[d.id]?.fingerprint != fp {
                seen[d.id] = (fp, now)
                dismissed.remove(d.id)
            }
            // Waiting or finished tiles are worth a word at once; busy ones once they settle.
            let settled = d.waiting || d.state == "done" || d.state == "failed" || now.timeIntervalSince(seen[d.id]!.since) >= Self.settle
            guard summarized[d.id] != fp, settled, !inFlight.contains(d.id), inFlight.count < Self.concurrency,
                  !d.text.isEmpty || d.detail != nil else { continue }
            summarize(d, fingerprint: fp, base: base)
        }
        let boardState = digests.map { "\($0.id)\($0.state)\($0.waiting)\(summaries[$0.id]?.summary ?? "")" }.joined().hashValue
        if !briefing, inFlight.isEmpty, briefedState != boardState, now.timeIntervalSince(lastBriefAt) >= Self.briefEvery || brief == nil {
            makeBrief(digests.map { var d = $0; d.summary = summaries[d.id]?.summary; return d }, state: boardState, base: base)
        }
    }

    private func summarize(_ digest: Steward.Digest, fingerprint: Int, base: URL) {
        inFlight.insert(digest.id)
        call(base: base, messages: Steward.tileMessages(digest), maxTokens: 160) { [weak self] data in
            guard let self else { return }
            self.inFlight.remove(digest.id)
            guard let data, let summary = try? Steward.tileSummary(fromCompletion: data) else { return }
            self.summarized[digest.id] = fingerprint
            if self.summaries[digest.id] != summary { self.summaries[digest.id] = summary }
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
        let account = Self.account
        Task { [session] in
            let key = await Task.detached(priority: .utility) { Keychain.get(account: account) }.value
            do {
                let request = try Steward.request(base: base, key: key, model: model, messages: messages, maxTokens: maxTokens)
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw Steward.Failure.unreadable(code == 401 || code == 403 ? "the endpoint refused the key (HTTP \(code))" : "HTTP \(code)")
                }
                // The endpoint answers again: an earlier failure no longer stands.
                if case .failed = self.status { self.status = .idle }
                done(data)
            } catch {
                self.retryAt = Date().addingTimeInterval(60)
                self.status = .failed(error.localizedDescription)
                done(nil)
            }
        }
    }
}
