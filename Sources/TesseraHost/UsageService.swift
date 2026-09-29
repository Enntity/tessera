import AppKit
import Foundation
import Observation
import TesseraKit

/// Keeps every connected provider's balance / limits fresh for the sidebar and remote clients.
@Observable
@MainActor
public final class UsageService {
    public private(set) var configs: [UsageProviderConfig] = []
    public private(set) var readings: [String: UsageReading] = [:]
    public var codexRateLimits: CodexRateLimits? {
        didSet { applyLocalReadings() }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAttempt: [String: Date] = [:]
    @ObservationIgnored private var retryAt: [String: Date] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var lastGood: [String: Date] = [:]
    @ObservationIgnored private let claudeLocal = ClaudeLocalUsage()
    /// When to next try the official Claude plan endpoint after it refused us.
    @ObservationIgnored private var claudeOfficialRetryAt: Date?
    /// The last official Claude reading and why the latest attempt didn't get one, so a refused
    /// or skipped attempt keeps showing what's left instead of only local counts.
    @ObservationIgnored private var claudeOfficial: UsageReading?
    @ObservationIgnored private var claudeNote: String?
    @ObservationIgnored private let store: URL
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    public static let refreshInterval: TimeInterval = 300

    public init(directory: URL) {
        store = directory.appendingPathComponent("providers.json")
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([UsageProviderConfig].self, from: data) {
            configs = saved
        } else {
            // Local plan readers need no key, so they're on by default.
            configs = [UsageProviderConfig(id: "codex-plan", kind: .codexPlan)]
        }
    }

    public var orderedReadings: [UsageReading] {
        configs.compactMap { readings[$0.id] }
    }

    public func start() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    public func add(_ config: UsageProviderConfig, key: String?) {
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        if let key { Keychain.set(key, account: "provider." + config.id) }
        save()
        refresh(config, force: true)
    }

    public func update(_ config: UsageProviderConfig, key: String?) {
        guard let i = configs.firstIndex(where: { $0.id == config.id }) else { return add(config, key: key) }
        configs[i] = config
        if let key { Keychain.set(key, account: "provider." + config.id) }
        save()
        refresh(config, force: true)
    }

    public func remove(id: String) {
        configs.removeAll { $0.id == id }
        readings[id] = nil
        Keychain.set(nil, account: "provider." + id)
        save()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        configs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    /// Drag-reorder: `id` takes `target`'s place, pushing it down (or up when dragging downward).
    public func move(_ id: String, onto target: String) {
        guard id != target, let from = configs.firstIndex(where: { $0.id == id }),
              let to = configs.firstIndex(where: { $0.id == target }) else { return }
        configs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        save()
    }

    public func hasKey(_ id: String) -> Bool { Keychain.get(account: "provider." + id) != nil }

    public func refreshAll() {
        for c in configs { refresh(c) }
    }

    /// Asks the provider for fresh numbers, unless it was asked too recently or told us to back off.
    /// `force` (a changed key or config) skips the spacing but never a server-requested backoff.
    public func refresh(_ config: UsageProviderConfig, force: Bool = false) {
        let spec = config.kind.spec
        let now = Date()
        if config.kind != .codexPlan {
            if let until = retryAt[config.id], now < until { return }
            if !force, let last = lastAttempt[config.id], now.timeIntervalSince(last) < UsageAPI.minimumInterval(for: config.kind) { return }
        }
        switch config.kind {
        case .codexPlan:
            readings[config.id] = UsageAPI.reading(for: codexRateLimits, config: config)
            return
        case .claudePlan:
            lastAttempt[config.id] = now
            refreshClaudePlan(config, force: force)
            return
        default:
            if spec.keyHint != nil, config.kind != .custom, !hasKey(config.id) {
                readings[config.id] = UsageReading(id: config.id, name: config.name, symbol: spec.symbol, status: .needsKey, topUpURL: spec.topUpURL)
                return
            }
        }
        var current = readings[config.id] ?? UsageReading(id: config.id, name: config.name, symbol: spec.symbol, topUpURL: spec.topUpURL)
        if current.headline.isEmpty { current.status = .loading }
        readings[config.id] = current

        lastAttempt[config.id] = now
        let secret = Keychain.get(account: "provider." + config.id)
        Task { [session] in
            // The Claude sign-in read can raise a Keychain prompt; keep it off the main thread.
            let key: String? = config.kind == .claudePlan ? await ClaudeTokenCache.shared.token() : secret
            guard let request = UsageAPI.request(for: config, key: key) else {
                self.readings[config.id] = self.failure(config, config.kind == .claudePlan ? "Sign in to Claude Code first" : "Incomplete configuration")
                return
            }
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 429 || code >= 500 {
                    self.backOff(config, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), code: code)
                    return
                }
                guard (200..<300).contains(code) else {
                    if code == 401, config.kind == .claudePlan { await ClaudeTokenCache.shared.invalidate() }
                    throw UsageAPI.Failure.http(code, String(decoding: data, as: UTF8.self))
                }
                self.readings[config.id] = try UsageAPI.parse(data, for: config)
                self.failures[config.id] = nil
                self.retryAt[config.id] = nil
                self.lastGood[config.id] = Date()
            } catch {
                self.readings[config.id] = self.failure(config, error.localizedDescription)
            }
        }
    }

    /// Claude plan: the official 5-hour / weekly limits when Claude Code's sign-in works, otherwise
    /// usage counted from local transcripts plus a hint — never a dead error.
    private func refreshClaudePlan(_ config: UsageProviderConfig, force: Bool) {
        if readings[config.id] == nil {
            readings[config.id] = UsageReading(id: config.id, name: config.name, symbol: config.kind.spec.symbol, status: .loading)
        }
        let tryOfficial = force || claudeOfficialRetryAt.map { Date() >= $0 } ?? true
        let local = claudeLocal
        Task { [session] in
            let counted = await Task.detached(priority: .utility) { local.refresh() }.value
            var official: UsageReading?
            var note: String?
            if tryOfficial {
                if let token = await ClaudeTokenCache.shared.token(), let request = UsageAPI.request(for: config, key: token) {
                    do {
                        let (data, response) = try await session.data(for: request)
                        let http = response as? HTTPURLResponse
                        switch http?.statusCode ?? 0 {
                        case 200..<300:
                            official = try? UsageAPI.parse(data, for: config)
                            self.claudeOfficialRetryAt = nil
                        case 401, 403:
                            await ClaudeTokenCache.shared.invalidate()
                            note = "Official limits need a fresh Claude Code sign-in — run `claude` once in a terminal."
                            self.claudeOfficialRetryAt = Date().addingTimeInterval(1800)
                        case 429:
                            note = "Official limits are rate-limited right now."
                            self.claudeOfficialRetryAt = Date().addingTimeInterval(
                                UsageAPI.backoff(failures: 1, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")))
                        case let code:
                            note = "Official limits unavailable (HTTP \(code))."
                            self.claudeOfficialRetryAt = Date().addingTimeInterval(900)
                        }
                    } catch {
                        note = "Official limits unreachable: \(error.localizedDescription)"
                        self.claudeOfficialRetryAt = Date().addingTimeInterval(300)
                    }
                } else {
                    note = "Sign in to Claude Code (run `claude`) for official plan limits."
                    self.claudeOfficialRetryAt = Date().addingTimeInterval(1800)
                }
                self.claudeNote = note
            } else {
                note = self.claudeNote
            }
            if let official { self.claudeOfficial = official }
            if var reading = self.claudeOfficial {
                if official == nil {
                    reading.message = [note, "limits from \(reading.updatedAt.shortAge()) ago"].compactMap { $0 }.joined(separator: " · ")
                }
                reading.lines.append("Local · 5h \(counted.fiveHours.tokens.compactTokens) · week \(counted.week.tokens.compactTokens) tokens")
                self.readings[config.id] = reading
            } else {
                self.readings[config.id] = UsageAPI.claudeLocalReading(
                    config: config, fiveHours: (counted.fiveHours.tokens, counted.fiveHours.replies),
                    week: (counted.week.tokens, counted.week.replies), note: note)
            }
        }
    }

    /// Keep showing the last good numbers, say they're held, and wait as long as the provider asks.
    private func backOff(_ config: UsageProviderConfig, retryAfter: String?, code: Int) {
        let count = (failures[config.id] ?? 0) + 1
        failures[config.id] = count
        let until = Date().addingTimeInterval(UsageAPI.backoff(failures: count, retryAfter: retryAfter))
        retryAt[config.id] = until
        let why = code == 429 ? "Rate limited" : "Provider error \(code)"
        let when = until.formatted(date: .omitted, time: .shortened)
        if var held = readings[config.id], held.status == .ok, let good = lastGood[config.id] {
            held.message = "\(why) · data from \(good.shortAge()) ago · retry \(when)"
            readings[config.id] = held
        } else {
            var r = failure(config, "Retrying at \(when)")
            r.headline = why
            readings[config.id] = r
        }
    }

    private func applyLocalReadings() {
        for c in configs where c.kind == .codexPlan { refresh(c) }
    }

    private func failure(_ config: UsageProviderConfig, _ message: String) -> UsageReading {
        let spec = config.kind.spec
        return UsageReading(id: config.id, name: config.name, symbol: spec.symbol, headline: "Unavailable",
                            status: .error, message: message, topUpURL: config.customTopUpURL ?? spec.topUpURL)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(configs) { try? data.write(to: store, options: .atomic) }
    }

}

/// Claude Code stores its OAuth sign-in as JSON in the login Keychain. macOS asks the user before
/// letting Tessera read it, and nothing is read unless the Claude plan provider is added. The token
/// is only ever sent to Anthropic. Only the `claude` CLI renews it, so when it has expired Tessera
/// renews it the same way and writes it back, keeping a single sign-in for both.
actor ClaudeTokenCache {
    static let shared = ClaudeTokenCache()
    private static let service = "Claude Code-credentials"
    private var cached: (token: ClaudeOAuth.Token, at: Date)?
    private var renewing: Task<String?, Never>?

    func token() async -> String? {
        let now = Date()
        if let cached, now.timeIntervalSince(cached.at) < 600, cached.token.expiresAt > now.addingTimeInterval(ClaudeOAuth.margin) {
            return cached.token.value
        }
        guard let raw = Keychain.firstGenericPassword(service: Self.service) else { return nil }
        if let t = ClaudeOAuth.token(in: raw, now: now) {
            cached = (t, now)
            return t.value
        }
        // One renewal at a time: a second use of the same refresh token would fail once it rotates.
        if let renewing { return await renewing.value }
        let task = Task { await renew(raw) }
        renewing = task
        defer { renewing = nil }
        return await task.value
    }

    private func renew(_ raw: String) async -> String? {
        guard let request = ClaudeOAuth.refreshRequest(raw),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let renewed = ClaudeOAuth.renewed(raw, response: data, now: Date()),
              let t = ClaudeOAuth.token(in: renewed, now: Date()) else { return nil }
        Keychain.updateGenericPassword(service: Self.service, value: renewed)
        cached = (t, Date())
        return t.value
    }

    func invalidate() { cached = nil }
}

/// Claude Code's sign-in format and token renewal, mirroring its CLI.
enum ClaudeOAuth {
    struct Token { var value: String; var expiresAt: Date }
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Treat a token this close to expiry as expired, so a request never races it.
    static let margin: TimeInterval = 300

    private static func oauth(_ credentials: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(credentials.utf8)) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
    }

    /// The access token, when present and not about to expire.
    static func token(in credentials: String, now: Date) -> Token? {
        guard let o = oauth(credentials), let value = o["accessToken"] as? String,
              let ms = (o["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        let expiresAt = Date(timeIntervalSince1970: ms / 1000)
        return expiresAt > now.addingTimeInterval(margin) ? Token(value: value, expiresAt: expiresAt) : nil
    }

    static func refreshRequest(_ credentials: String) -> URLRequest? {
        guard let o = oauth(credentials), let refresh = o["refreshToken"] as? String else { return nil }
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The token endpoint's edge rejects unfamiliar default agents before reading the request.
        r.setValue("Tessera", forHTTPHeaderField: "User-Agent")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
            "scope": (o["scopes"] as? [String] ?? []).joined(separator: " ")])
        return r
    }

    /// The stored credentials with the renewed tokens merged in and every other field kept.
    static func renewed(_ credentials: String, response: Data, now: Date) -> String? {
        guard var root = try? JSONSerialization.jsonObject(with: Data(credentials.utf8)) as? [String: Any],
              var o = root["claudeAiOauth"] as? [String: Any],
              let r = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let access = r["access_token"] as? String, let expiresIn = (r["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        o["accessToken"] = access
        if let refresh = r["refresh_token"] as? String { o["refreshToken"] = refresh }
        o["expiresAt"] = Int64((now.timeIntervalSince1970 + expiresIn) * 1000)
        root["claudeAiOauth"] = o
        return (try? JSONSerialization.data(withJSONObject: root)).map { String(decoding: $0, as: UTF8.self) }
    }
}
