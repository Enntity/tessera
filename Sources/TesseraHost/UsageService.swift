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
    /// Providers shown with fixed readings (`pin`), never asked.
    @ObservationIgnored private var pinned: Set<String> = []
    /// The user agreed to Tessera reading Claude Code's `/usage` in the background (`ClaudeUsageProbe`).
    public private(set) var claudeChecksOn = Preferences.store.bool(forKey: "tessera.claudeUsageChecks") {
        didSet { Preferences.store.set(claudeChecksOn, forKey: "tessera.claudeUsageChecks") }
    }
    /// The plan as `/usage` last showed it, and when; and why the last read didn't get it.
    @ObservationIgnored private var claudePlan: (windows: [ClaudeUsageScreen.Window], at: Date)?
    @ObservationIgnored private var claudePlanNote: String?
    @ObservationIgnored private var claudeProbe: ClaudeUsageProbe?
    /// When `/usage` may next be read: every few minutes, and longer after Anthropic said not now.
    @ObservationIgnored private var claudeProbeAt = Date.distantPast
    static let claudeProbeEvery: TimeInterval = 600
    @ObservationIgnored private let directory: URL
    /// What `claude auth status` said last, and when: asked again every few minutes, or when forced.
    @ObservationIgnored private var claudeAuth: (signedIn: Bool?, at: Date)?
    /// When the user last started signing in from the card: refusals from before then are answered.
    @ObservationIgnored private var claudeSignInStartedAt: Date?
    /// Claude Code in a terminal isn't signed in (or its sign-in has run out): the card offers to sign in.
    static let claudeSignIn = UsageReading.Fix(title: "Sign in to Claude Code", command: "claude auth login")
    /// Signed in, but plan limits aren't being read: the card offers to (Tessera asks first).
    static let claudeConnect = UsageReading.Fix(title: "Show plan limits", command: nil)
    @ObservationIgnored private let store: URL
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    public static let refreshInterval: TimeInterval = 300

    public init(directory: URL) {
        store = directory.appendingPathComponent("providers.json")
        self.directory = directory
        // Local plan readers need no key, so they're on by default.
        configs = StateFile.loadList(UsageProviderConfig.self, from: store) ?? [UsageProviderConfig(id: "codex-plan", kind: .codexPlan)]
    }

    public var orderedReadings: [UsageReading] {
        configs.compactMap { readings[$0.id] }
    }

    public func start() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer?.tolerance = 30
        // Plan limits once came through Claude Code's status line; put back the one that was replaced.
        ClaudeStatusTap.retire(in: directory)
    }

    /// Starts (the user has agreed) or stops Tessera reading Claude Code's `/usage` in the background.
    public func setClaudeChecks(_ on: Bool) {
        claudeChecksOn = on
        claudePlan = nil
        claudePlanNote = nil
        claudeProbeAt = .distantPast
        for c in configs where c.kind == .claudePlan { refresh(c, force: true) }
    }

    /// Reads `/usage` once; the card is redrawn with what it said.
    private func readClaudePlan(for config: UsageProviderConfig) {
        let probe = ClaudeUsageProbe()
        claudeProbe = probe
        claudeProbeAt = Date().addingTimeInterval(Self.claudeProbeEvery)
        probe.run { [weak self] result in
            guard let self else { return }
            self.claudeProbe = nil
            switch result {
            case .read(let windows):
                self.claudePlan = (windows, Date())
                self.claudePlanNote = nil
            case .refused:
                self.claudeProbeAt = Date().addingTimeInterval(3 * Self.claudeProbeEvery)
                self.claudePlanNote = "Anthropic didn't give the plan limits just now; trying again later."
            case .failed(let why):
                self.claudePlanNote = why
            }
            self.refresh(config)
        }
    }

    #if DEBUG
    /// Development aid (`scripts/demo-shot.sh`): shows these readings, as of now, for the connected
    /// providers they name.
    public func pin(_ pins: [UsageReading]) {
        for var r in pins where configs.contains(where: { $0.id == r.id }) {
            r.updatedAt = Date()
            pinned.insert(r.id)
            readings[r.id] = r
        }
    }
    #endif

    public func add(_ config: UsageProviderConfig, key: String?) {
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        if let key { Keychain.set(key, account: Self.account(config.id)) }
        save()
        refresh(config, force: true)
    }

    public func remove(id: String) {
        configs.removeAll { $0.id == id }
        readings[id] = nil
        Keychain.set(nil, account: Self.account(id))
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

    /// Checked without reading the key, so rendering never raises a Keychain prompt.
    public func hasKey(_ id: String) -> Bool { Keychain.contains(account: Self.account(id)) }

    private static func account(_ id: String) -> String { "provider." + id }

    public func refreshAll() {
        for c in configs { refresh(c) }
    }

    /// Asks the provider for fresh numbers, unless it was asked too recently or told us to back off.
    /// `force` (a changed key or config) skips the spacing but never a server-requested backoff.
    public func refresh(_ config: UsageProviderConfig, force: Bool = false) {
        let spec = config.kind.spec
        let now = Date()
        guard !pinned.contains(config.id) else { return }
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
        let account = Self.account(config.id)
        Task { [session] in
            // Reading a secret can raise a Keychain prompt; keep it off the main thread.
            let key = await Task.detached(priority: .utility) { Keychain.get(account: account) }.value
            guard let request = UsageAPI.request(for: config, key: key) else {
                self.readings[config.id] = self.failure(config, "Incomplete configuration")
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
                guard (200..<300).contains(code) else { throw UsageAPI.Failure.http(code, String(decoding: data, as: UTF8.self)) }
                self.readings[config.id] = try UsageAPI.parse(data, for: config)
                self.failures[config.id] = nil
                self.retryAt[config.id] = nil
                self.lastGood[config.id] = Date()
            } catch {
                self.readings[config.id] = self.failure(config, error.localizedDescription)
            }
        }
    }

    /// Claude plan: the 5-hour and weekly limits as Claude Code's `/usage` last showed them (once the
    /// user has agreed to Tessera reading it), with the usage counted from local transcripts beside
    /// them; without them, the counted usage alone — never a dead error — and the one thing that
    /// would add them.
    private func refreshClaudePlan(_ config: UsageProviderConfig, force: Bool) {
        if readings[config.id] == nil {
            readings[config.id] = UsageReading(id: config.id, name: config.name, symbol: config.kind.spec.symbol, status: .loading)
        }
        let local = claudeLocal
        let known = force ? nil : claudeAuth.flatMap { Date().timeIntervalSince($0.at) < 600 ? $0.signedIn : nil }
        Task {
            let (counted, asked) = await Task.detached(priority: .utility) {
                (local.refresh(), known == nil ? ClaudeLocalUsage.signedIn() : known)
            }.value
            self.claudeAuth = (asked, Date())
            // Couldn't ask (no `claude` on the PATH): nothing to offer about signing in. Signed in, its
            // credentials may still have run out; its last reply in a terminal says so.
            let expired = counted.signInRefusedAt.map { $0 > self.claudeSignInStartedAt ?? .distantPast } ?? false
            let signedIn = (asked ?? true) && !expired
            if self.claudeChecksOn, signedIn, self.claudeProbe == nil, Date() >= self.claudeProbeAt {
                self.readClaudePlan(for: config)
            }
            var reading: UsageReading
            if self.claudeChecksOn, let plan = self.claudePlan {
                reading = UsageAPI.claudeUsageReading(plan.windows, readAt: plan.at, config: config)
                reading.lines.append("Local · 5h \(counted.fiveHours.tokens.compactTokens) · week \(counted.week.tokens.compactTokens) tokens")
                if reading.message == nil { reading.message = self.claudePlanNote }
            } else {
                reading = UsageAPI.claudeLocalReading(
                    config: config, fiveHours: (counted.fiveHours.tokens, counted.fiveHours.replies),
                    week: (counted.week.tokens, counted.week.replies),
                    limit: counted.limit.map { ($0.window, $0.resetsAt) },
                    note: !signedIn ? (expired ? "Claude Code's sign-in has run out; sign in again for its plan limits."
                                               : "Sign in to Claude Code for its usage and plan limits.")
                        : self.claudeChecksOn ? self.claudePlanNote ?? "Reading plan limits from Claude Code…" : nil)
            }
            reading.fix = !signedIn ? Self.claudeSignIn : self.claudeChecksOn ? nil : Self.claudeConnect
            self.readings[config.id] = reading
        }
    }

    /// A reading's fix has been started (a sign-in running in a terminal): look again soon, a few
    /// times, so the card corrects itself once it has worked.
    public func fixStarted(_ id: String) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        if config.kind == .claudePlan { claudeSignInStartedAt = Date() }
        for delay in [20.0, 60, 180, 300] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refresh(config, force: true) }
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
        StateFile.save(configs, to: store)
    }

}
