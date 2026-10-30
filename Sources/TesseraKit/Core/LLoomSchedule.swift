import Foundation

/// A LLooM head's schedule (`GET /gateway/schedule`): the leases agents hold on shared hardware and
/// the jobs they report. Building the request, reading the reply and turning it into tiles are pure,
/// so they are tested without a network.
public enum LLoomSchedule {
    public struct Board: Decodable, Equatable, Sendable {
        /// The head's clock, in milliseconds since 1970; every age here is measured from it.
        public var now: Double
        public var resources: [Resource]
        public var reservations: [Reservation]
        public var jobs: [Job]
    }

    public struct Resource: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var description: String?
        public var hosts: [String]?
        public var capacity: Int?
        public var holders: [String]?
        public var queue: [String]?
        /// The head can't use this resource's configuration.
        public var error: String?
    }

    public struct Reservation: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var resource: String
        public var owner: String
        public var purpose: String?
        public var session: String?
        /// queued, acquiring, active, releasing, stuck, released or failed.
        public var state: String
        public var startedAt: Double?
        public var expiresAt: Double?
        /// When the head warned that the lease is running out (cleared by a renewal).
        public var warnedAt: Double?
        public var updatedAt: Double?
        public var error: String?
    }

    public struct Job: Decodable, Equatable, Sendable, Identifiable {
        public struct Note: Decodable, Equatable, Sendable {
            public var at: Double
            public var text: String
        }

        public struct Progress: Decodable, Equatable, Sendable {
            public var done: Double
            public var total: Double?
            public var unit: String?
        }

        public var id: String
        public var title: String
        public var owner: String
        public var session: String?
        public var resource: String?
        /// running, done, failed or cancelled.
        public var state: String
        public var startedAt: Double
        public var heartbeatAt: Double
        public var endedAt: Double?
        /// When a running job went quiet for longer than it said it would.
        public var stalledAt: Double?
        public var note: String?
        public var notes: [Note]
        public var progress: Progress?
        public var metrics: [String: Metric]
        public var receipt: String?
    }

    public enum Metric: Decodable, Equatable, Sendable, CustomStringConvertible {
        case number(Double), text(String)

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { self = .number(number) } else { self = .text(try value.decode(String.self)) }
        }

        public var description: String {
            switch self {
            case .number(let n): String(format: "%g", n)
            case .text(let s): s
            }
        }
    }

    /// The head's address, if it is one Tessera will talk to: http(s) with a host.
    public static func baseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    public static func request(base: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("gateway/schedule"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public static func parse(_ data: Data) throws -> Board {
        try JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: Tiles

    /// A job, or a lease that needs the user, as the board shows it.
    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var activity: TileActivity
        public var detail: String?
        /// When it last changed in a way the user would care about: a report, its end, or the moment
        /// it began to need them (so a job seen before it stalled lights up again).
        public var changedAt: Date
        public var lastActivityAt: Date
        /// 0...1 when the job reports a total.
        public var progress: Double?
        public var notes: [ConversationItem]
        /// The reporting agent's conversation (`claude:<id>`, `codex:<id>`), when it said.
        public var session: String?

        /// Whether the item wants the user's attention: a failed or stalled job, a lease that is
        /// overdue or whose restore failed.
        public var wantsUser: Bool { activity == .needsInput || activity == .failed }
    }

    /// Tile ids are `lloom:` and the job or reservation id, so they never collide with other tiles.
    public static let idPrefix = "lloom:"

    /// Running jobs and those that ended within `lookback`, then leases that need the user: one
    /// running out, or one whose restore failed.
    public static func items(_ board: Board, lookback: TimeInterval) -> [Item] {
        let now = date(board.now)
        var out: [Item] = []
        for job in board.jobs {
            let ended = job.endedAt.map(date)
            if let ended, now.timeIntervalSince(ended) > lookback { continue }
            out.append(item(job, now: now))
        }
        for lease in board.reservations {
            if let alert = item(lease, now: now) { out.append(alert) }
        }
        return out
    }

    static func item(_ job: Job, now: Date) -> Item {
        let heartbeat = date(job.heartbeatAt)
        let stalled = job.state == "running" ? job.stalledAt.map(date) : nil
        let activity: TileActivity = switch job.state {
        case "running": stalled == nil ? .working : .failed
        case "done": .done
        case "failed": .failed
        default: .idle
        }
        var detail = [job.note, progressText(job.progress), metricsText(job.metrics)].compactMap { $0 }.joined(separator: " · ")
        if stalled != nil { detail = "No report for \(heartbeat.shortAge(now: now))" + (detail.isEmpty ? "" : " · \(detail)") }
        if detail.isEmpty, let receipt = job.receipt { detail = receipt }
        let changed = stalled ?? job.endedAt.map(date) ?? heartbeat
        let fraction = job.progress.flatMap { p in p.total.map { min(1, max(0, p.done / $0)) } }
        return Item(id: idPrefix + job.id, title: job.title,
                    subtitle: [job.owner, job.resource].compactMap { $0 }.joined(separator: " · "),
                    activity: activity, detail: detail.isEmpty ? nil : detail, changedAt: changed,
                    lastActivityAt: job.endedAt.map(date) ?? heartbeat, progress: fraction,
                    notes: job.notes.enumerated().map { i, note in
                        ConversationItem(id: "\(job.id)-\(i)", role: .assistant, text: note.text, timestamp: date(note.at))
                    },
                    session: job.session)
    }

    static func item(_ lease: Reservation, now: Date) -> Item? {
        let changed = date(lease.warnedAt ?? lease.updatedAt ?? lease.startedAt ?? 0)
        switch lease.state {
        case "stuck":
            return Item(id: idPrefix + lease.id, title: "\(lease.resource) restore failed", subtitle: "\(lease.owner) · lease",
                        activity: .failed, detail: lease.error ?? "Restore failed; release it again to retry",
                        changedAt: changed, lastActivityAt: changed, progress: nil, notes: [], session: lease.session)
        case "active" where lease.warnedAt != nil:
            let expires = lease.expiresAt.map(date)
            let overdue = expires.map { $0 <= now } ?? false
            let left = expires.map { overdue ? "overdue" : "\(now.shortAge(now: $0)) left" } ?? "running out"
            return Item(id: idPrefix + lease.id, title: "\(lease.resource) lease \(overdue ? "overdue" : "expiring")",
                        subtitle: "\(lease.owner) · lease", activity: .needsInput,
                        detail: "\(left) · lloom renew \(lease.resource)", changedAt: changed, lastActivityAt: changed,
                        progress: nil, notes: [], session: lease.session)
        default:
            return nil
        }
    }

    // MARK: The band

    /// One resource as the Fleet band shows it.
    public struct Lane: Equatable, Sendable, Identifiable {
        public enum State: Sendable { case free, held, attention, unusable }
        public var id: String
        public var state: State
        /// Who holds it, the soonest-ending first.
        public var holders: [String]
        public var purpose: String?
        public var remaining: TimeInterval?
        public var queued: Int
        public var capacity: Int
        public var help: String
    }

    public static func lanes(_ board: Board) -> [Lane] {
        let now = date(board.now)
        let byId = Dictionary(board.reservations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return board.resources.map { resource in
            let held = (resource.holders ?? []).compactMap { byId[$0] }
            let queued = (resource.queue ?? []).compactMap { byId[$0] }
            let capacity = resource.capacity ?? 1
            let remaining = held.compactMap { $0.expiresAt.map { date($0).timeIntervalSince(now) } }.min()
            let state: Lane.State = resource.error != nil ? .unusable
                : held.contains { $0.state == "stuck" || $0.warnedAt != nil } ? .attention
                : held.isEmpty ? .free : .held
            var help = [resource.description, resource.hosts.map { $0.joined(separator: ", ") }].compactMap { $0 }
            if let error = resource.error { help.append(error) }
            for lease in held {
                help.append("\(lease.owner) (\(lease.state))" + (lease.purpose.map { ": \($0)" } ?? "") + (lease.error.map { " — \($0)" } ?? ""))
            }
            if !queued.isEmpty { help.append("Waiting: " + queued.map(\.owner).joined(separator: ", ")) }
            return Lane(id: resource.id, state: state, holders: held.map(\.owner), purpose: held.first?.purpose,
                        remaining: remaining, queued: queued.count, capacity: capacity, help: help.joined(separator: "\n"))
        }
    }

    // MARK: Text

    static func progressText(_ progress: Job.Progress?) -> String? {
        guard let progress else { return nil }
        let done = Metric.number(progress.done).description
        let unit = progress.unit.map { " \($0)" } ?? ""
        return progress.total.map { "\(done)/\(Metric.number($0))\(unit)" } ?? "\(done)\(unit)"
    }

    static func metricsText(_ metrics: [String: Metric]) -> String? {
        metrics.isEmpty ? nil : metrics.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " ")
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
