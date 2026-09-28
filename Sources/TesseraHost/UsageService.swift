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
        refresh(config)
    }

    public func update(_ config: UsageProviderConfig, key: String?) {
        guard let i = configs.firstIndex(where: { $0.id == config.id }) else { return add(config, key: key) }
        configs[i] = config
        if let key { Keychain.set(key, account: "provider." + config.id) }
        save()
        refresh(config)
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

    public func hasKey(_ id: String) -> Bool { Keychain.get(account: "provider." + id) != nil }

    public func refreshAll() {
        for c in configs { refresh(c) }
    }

    public func refresh(_ config: UsageProviderConfig) {
        let spec = config.kind.spec
        switch config.kind {
        case .codexPlan:
            readings[config.id] = UsageAPI.reading(for: codexRateLimits, config: config)
            return
        case .claudePlan:
            break
        default:
            if spec.keyHint != nil, config.kind != .custom, !hasKey(config.id) {
                readings[config.id] = UsageReading(id: config.id, name: config.name, symbol: spec.symbol, status: .needsKey, topUpURL: spec.topUpURL)
                return
            }
        }
        var current = readings[config.id] ?? UsageReading(id: config.id, name: config.name, symbol: spec.symbol, topUpURL: spec.topUpURL)
        if current.headline.isEmpty { current.status = .loading }
        readings[config.id] = current

        let secret = Keychain.get(account: "provider." + config.id)
        Task { [session] in
            // The Claude sign-in read can raise a Keychain prompt; keep it off the main thread.
            let key: String? = config.kind == .claudePlan ? await ClaudeTokenCache.shared.token() : secret
            let result: UsageReading
            if let request = UsageAPI.request(for: config, key: key) {
                do {
                    let (data, response) = try await session.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        if code == 401, config.kind == .claudePlan { await ClaudeTokenCache.shared.invalidate() }
                        throw UsageAPI.Failure.http(code, String(decoding: data, as: UTF8.self))
                    }
                    result = try UsageAPI.parse(data, for: config)
                } catch {
                    result = self.failure(config, error.localizedDescription)
                }
            } else {
                result = self.failure(config, config.kind == .claudePlan ? "Sign in to Claude Code first" : "Incomplete configuration")
            }
            self.readings[config.id] = result
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
/// is only ever sent to api.anthropic.com, and is re-read at most every ten minutes.
actor ClaudeTokenCache {
    static let shared = ClaudeTokenCache()
    private var cached: (token: String, at: Date)?

    func token() -> String? {
        if let cached, Date().timeIntervalSince(cached.at) < 600 { return cached.token }
        guard let raw = Keychain.firstGenericPassword(service: "Claude Code-credentials"),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        cached = (token, Date())
        return token
    }

    func invalidate() { cached = nil }
}
