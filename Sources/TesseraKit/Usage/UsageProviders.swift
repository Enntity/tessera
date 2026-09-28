import Foundation

/// A provider's current standing, in a shape every sidebar row can render.
public struct UsageReading: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, error, needsKey, loading }

    public var id: String
    public var name: String
    public var symbol: String
    /// The single number that matters: "$42.10 left", "5h 37% used".
    public var headline: String
    /// Remaining share for the gauge, 0...1, when the provider has a meaningful ceiling.
    public var remaining: Double?
    public var lines: [String]
    public var status: Status
    public var message: String?
    public var topUpURL: String?
    public var updatedAt: Date

    public init(id: String, name: String, symbol: String, headline: String = "", remaining: Double? = nil,
                lines: [String] = [], status: Status = .ok, message: String? = nil, topUpURL: String? = nil,
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.headline = headline
        self.remaining = remaining
        self.lines = lines
        self.status = status
        self.message = message
        self.topUpURL = topUpURL
        self.updatedAt = updatedAt
    }
}

public enum UsageProviderKind: String, Codable, Sendable, CaseIterable {
    case openrouter, deepseek, moonshot, openai, anthropic, xai, claudePlan, codexPlan, custom
}

/// User configuration for one connected provider. Secrets live in the Keychain, never here.
public struct UsageProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: UsageProviderKind
    public var name: String
    /// Monthly budget for spend-only providers, so they can still show a gauge.
    public var monthlyBudget: Double?
    public var customBalanceURL: String?
    public var customAuthHeader: String?
    /// Dot path into the JSON response, e.g. `data.balance`.
    public var customJSONPath: String?
    public var customTopUpURL: String?

    public init(id: String = UUID().uuidString, kind: UsageProviderKind, name: String? = nil, monthlyBudget: Double? = nil,
                customBalanceURL: String? = nil, customAuthHeader: String? = nil, customJSONPath: String? = nil, customTopUpURL: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.spec.name
        self.monthlyBudget = monthlyBudget
        self.customBalanceURL = customBalanceURL
        self.customAuthHeader = customAuthHeader
        self.customJSONPath = customJSONPath
        self.customTopUpURL = customTopUpURL
    }
}

public struct UsageProviderSpec: Sendable {
    public var name: String
    public var symbol: String
    public var topUpURL: String?
    /// What kind of secret this provider needs, shown as the field placeholder. Nil means no key.
    public var keyHint: String?
    public var help: String
}

public extension UsageProviderKind {
    var spec: UsageProviderSpec {
        switch self {
        case .openrouter:
            .init(name: "OpenRouter", symbol: "arrow.triangle.branch", topUpURL: "https://openrouter.ai/settings/credits",
                  keyHint: "sk-or-…", help: "Any OpenRouter API key. Shows remaining credits.")
        case .deepseek:
            .init(name: "DeepSeek", symbol: "water.waves", topUpURL: "https://platform.deepseek.com/top_up",
                  keyHint: "sk-…", help: "DeepSeek API key. Shows account balance.")
        case .moonshot:
            .init(name: "Moonshot / Kimi", symbol: "moon.stars", topUpURL: "https://platform.moonshot.ai/console/pay",
                  keyHint: "sk-…", help: "Moonshot API key. Shows available balance.")
        case .openai:
            .init(name: "OpenAI API", symbol: "circle.hexagonpath", topUpURL: "https://platform.openai.com/settings/organization/billing/overview",
                  keyHint: "Admin key sk-admin-…", help: "Organization admin key. Shows spend this month; set a budget for a gauge.")
        case .anthropic:
            .init(name: "Anthropic API", symbol: "a.circle", topUpURL: "https://console.anthropic.com/settings/billing",
                  keyHint: "Admin key sk-ant-admin…", help: "Organization admin key. Shows spend this month; set a budget for a gauge.")
        case .xai:
            .init(name: "xAI", symbol: "xmark.circle", topUpURL: "https://console.x.ai",
                  keyHint: "xai-…", help: "xAI API key. Shows key status; top up in the console.")
        case .claudePlan:
            .init(name: "Claude plan", symbol: "sparkle", topUpURL: "https://claude.ai/settings/usage",
                  keyHint: nil, help: "Reads the Claude Code sign-in from your Keychain to show 5-hour and weekly plan limits.")
        case .codexPlan:
            .init(name: "ChatGPT / Codex plan", symbol: "chevron.left.forwardslash.chevron.right", topUpURL: "https://chatgpt.com/codex/settings/usage",
                  keyHint: nil, help: "Reads the rate limits Codex records in ~/.codex/sessions. No key needed.")
        case .custom:
            .init(name: "Custom", symbol: "puzzlepiece.extension", topUpURL: nil,
                  keyHint: "API key (optional)", help: "Any JSON balance endpoint: URL, auth header and a dot path to the number.")
        }
    }
}

/// Pure request builders and response parsers, so the network layer stays a thin loop and the
/// parsing is unit-testable.
public enum UsageAPI {
    public enum Failure: Error, LocalizedError {
        case http(Int, String)
        case shape(String)
        public var errorDescription: String? {
            switch self {
            case .http(429, _): "Rate limited by the provider"
            case .http(let code, let body): "HTTP \(code): \(UsageAPI.errorMessage(from: body))"
            case .shape(let why): why
            }
        }
    }

    /// The human part of an API error body (`{"error":{"message":…}}` and friends), not raw JSON.
    public static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m.preview(120) }
            if let m = obj["message"] as? String { return m.preview(120) }
            if let m = obj["error"] as? String { return m.preview(120) }
        }
        return body.preview(120)
    }

    /// How often a provider may be asked. Plan-usage endpoints are shared with the official
    /// clients and rate-limit aggressively, so they get the longest spacing.
    public static func minimumInterval(for kind: UsageProviderKind) -> TimeInterval {
        switch kind {
        case .codexPlan: 0
        case .claudePlan: 300
        default: 60
        }
    }

    /// Wait before retrying after a 429/5xx: the server's Retry-After if given, else 5 min doubling to an hour.
    public static func backoff(failures: Int, retryAfter: String?) -> TimeInterval {
        if let raw = retryAfter?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(raw), seconds > 0 { return min(seconds, 3600) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = f.date(from: raw) { return min(max(date.timeIntervalSinceNow, 30), 3600) }
        }
        return min(3600, 300 * pow(2, Double(max(failures, 1) - 1)))
    }

    public static func monthStart(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    public static func request(for config: UsageProviderConfig, key: String?, now: Date = Date()) -> URLRequest? {
        func bearer(_ url: String) -> URLRequest? {
            guard let key, let u = URL(string: url) else { return nil }
            var r = URLRequest(url: u)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return r
        }
        let start = monthStart(now)
        switch config.kind {
        case .openrouter: return bearer("https://openrouter.ai/api/v1/credits")
        case .deepseek: return bearer("https://api.deepseek.com/user/balance")
        case .moonshot: return bearer("https://api.moonshot.ai/v1/users/me/balance")
        case .xai: return bearer("https://api.x.ai/v1/api-key")
        case .openai:
            return bearer("https://api.openai.com/v1/organization/costs?start_time=\(Int(start.timeIntervalSince1970))&bucket_width=1d&limit=31")
        case .anthropic:
            guard let key, let u = URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(ISO8601DateFormatter().string(from: start))&bucket_width=1d&limit=31") else { return nil }
            var r = URLRequest(url: u)
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return r
        case .claudePlan:
            guard let r0 = bearer("https://api.anthropic.com/api/oauth/usage") else { return nil }
            var r = r0
            r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            return r
        case .custom:
            guard let s = config.customBalanceURL, let u = URL(string: s) else { return nil }
            var r = URLRequest(url: u)
            if let key, !key.isEmpty {
                let header = config.customAuthHeader?.isEmpty == false ? config.customAuthHeader! : "Authorization"
                r.setValue(header == "Authorization" && !key.lowercased().hasPrefix("bearer ") ? "Bearer \(key)" : key,
                           forHTTPHeaderField: header)
            }
            return r
        case .codexPlan:
            return nil
        }
    }

    public static func parse(_ data: Data, for config: UsageProviderConfig, now: Date = Date()) throws -> UsageReading {
        let json = try JSONSerialization.jsonObject(with: data)
        let spec = config.kind.spec
        var reading = UsageReading(id: config.id, name: config.name, symbol: spec.symbol,
                                   topUpURL: config.customTopUpURL ?? spec.topUpURL, updatedAt: now)
        let obj = json as? [String: Any] ?? [:]
        switch config.kind {
        case .openrouter:
            guard let d = obj["data"] as? [String: Any], let credits = number(d["total_credits"]), let used = number(d["total_usage"]) else {
                throw Failure.shape("Unexpected OpenRouter response")
            }
            let left = credits - used
            reading.headline = money(left) + " left"
            reading.remaining = credits > 0 ? max(0, left / credits) : 0
            reading.lines = ["Used \(money(used)) of \(money(credits))"]
        case .deepseek:
            guard let infos = obj["balance_infos"] as? [[String: Any]], let first = infos.first,
                  let total = number(first["total_balance"]) else { throw Failure.shape("Unexpected DeepSeek response") }
            let currency = first["currency"] as? String ?? "USD"
            reading.headline = money(total, currency: currency) + " left"
            reading.lines = infos.dropFirst().compactMap { i in number(i["total_balance"]).map { money($0, currency: i["currency"] as? String ?? "") } }
            if obj["is_available"] as? Bool == false { reading.lines.insert("Balance insufficient for API calls", at: 0) }
        case .moonshot:
            guard let d = obj["data"] as? [String: Any], let available = number(d["available_balance"]) else {
                throw Failure.shape("Unexpected Moonshot response")
            }
            reading.headline = money(available) + " left"
            if let voucher = number(d["voucher_balance"]), voucher > 0 { reading.lines = ["Includes \(money(voucher)) vouchers"] }
        case .openai:
            let spent = (obj["data"] as? [[String: Any]] ?? []).flatMap { $0["results"] as? [[String: Any]] ?? [] }
                .compactMap { ($0["amount"] as? [String: Any]).flatMap { number($0["value"]) } }.reduce(0, +)
            applySpend(spent, to: &reading, budget: config.monthlyBudget)
        case .anthropic:
            // Cost report amounts are decimal strings in the currency's lowest unit (cents).
            let cents = (obj["data"] as? [[String: Any]] ?? []).flatMap { $0["results"] as? [[String: Any]] ?? [] }
                .compactMap { number($0["amount"]) }.reduce(0, +)
            applySpend(cents / 100, to: &reading, budget: config.monthlyBudget)
        case .xai:
            let blocked = (obj["api_key_blocked"] as? Bool ?? false) || (obj["team_blocked"] as? Bool ?? false)
            reading.headline = blocked ? "Key blocked" : "Key active"
            reading.status = blocked ? .error : .ok
            if let name = obj["name"] as? String { reading.lines = [name] }
        case .claudePlan:
            let windows: [(String, String)] = [("five_hour", "5h"), ("seven_day", "Week"), ("seven_day_opus", "Opus wk"), ("seven_day_sonnet", "Sonnet wk")]
            var parts: [String] = []
            var worst = 0.0
            for (key, label) in windows {
                guard let w = obj[key] as? [String: Any], let util = number(w["utilization"]) else { continue }
                worst = max(worst, util)
                var line = "\(label) \(Int(util.rounded()))%"
                if let reset = TranscriptSupport.date(w["resets_at"]) { line += " · resets \(relative(reset, now: now))" }
                parts.append(line)
            }
            guard !parts.isEmpty else { throw Failure.shape("No plan windows in response") }
            reading.headline = parts[0].components(separatedBy: " · ").first ?? parts[0]
            reading.remaining = max(0, 1 - worst / 100)
            reading.lines = parts
        case .custom:
            let path = config.customJSONPath ?? ""
            guard let value = number(dig(json, path: path)) else { throw Failure.shape("No number at `\(path)`") }
            reading.headline = String(format: "%.2f", value)
            if let budget = config.monthlyBudget, budget > 0 { reading.remaining = min(1, max(0, value / budget)) }
        case .codexPlan:
            throw Failure.shape("Codex plan is read from local sessions")
        }
        return reading
    }

    public static func reading(for limits: CodexRateLimits?, config: UsageProviderConfig, now: Date = Date()) -> UsageReading {
        let spec = config.kind.spec
        var reading = UsageReading(id: config.id, name: config.name, symbol: spec.symbol, topUpURL: spec.topUpURL, updatedAt: now)
        guard let limits else {
            reading.status = .error
            reading.headline = "No data yet"
            reading.message = "Codex has not recorded plan limits recently (API-key sessions don't report them)."
            return reading
        }
        var parts: [String] = []
        for (window, fallback) in [(limits.primary, "5h"), (limits.secondary, "Week")] {
            guard let w = window else { continue }
            let label = w.windowMinutes.map { $0 >= 1440 ? ($0 >= 10080 ? "Week" : "\($0 / 1440)d") : "\($0 / 60)h" } ?? fallback
            var line = "\(label) \(Int(w.usedPercent.rounded()))%"
            if let reset = w.resetsAt { line += " · resets \(relative(reset, now: now))" }
            parts.append(line)
        }
        let worst = [limits.primary?.usedPercent, limits.secondary?.usedPercent].compactMap { $0 }.max() ?? 0
        reading.headline = parts.first?.components(separatedBy: " · ").first ?? ""
        reading.remaining = max(0, 1 - worst / 100)
        reading.lines = parts + (limits.planType.map { ["Plan: \($0)"] } ?? [])
        return reading
    }

    static func applySpend(_ spent: Double, to reading: inout UsageReading, budget: Double?) {
        reading.headline = money(spent) + " this month"
        if let budget, budget > 0 {
            reading.remaining = max(0, 1 - spent / budget)
            reading.lines = ["Budget \(money(budget)) · \(money(max(0, budget - spent))) left"]
        }
    }

    public static func money(_ v: Double, currency: String = "USD") -> String {
        let symbol = ["USD": "$", "CNY": "¥", "EUR": "€", "GBP": "£"][currency] ?? ""
        return symbol.isEmpty ? String(format: "%.2f %@", v, currency) : symbol + String(format: "%.2f", v)
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func dig(_ json: Any, path: String) -> Any? {
        var current: Any? = json
        for part in path.split(separator: ".") {
            if let idx = Int(part), let arr = current as? [Any] {
                current = idx < arr.count ? arr[idx] : nil
            } else {
                current = (current as? [String: Any])?[String(part)]
            }
        }
        return current
    }

    static func relative(_ date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(s / 60)m" }
        if s < 86_400 { return "in \(s / 3600)h \((s % 3600) / 60)m" }
        return "in \(s / 86_400)d"
    }
}
