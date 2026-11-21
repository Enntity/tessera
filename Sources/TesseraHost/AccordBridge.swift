// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Observation
import TesseraKit
import TesseraAPI

enum AccordRequestError: LocalizedError {
    case activityNotShared

    var errorDescription: String? { "This host does not share session activity with this link." }
}

/// Native observations and delivery remain here; shared state/search/monitoring live in Accord.
/// Accord is the shared-state authority; Tessera never creates an offline coordination fork.
@Observable @MainActor
public final class AccordBridge {
    public private(set) var connected = false
    public private(set) var setupError: String?
    public private(set) var searchQuery = ""
    public private(set) var searchResults: [AgentAppSession] = []
    public private(set) var searchError: String?
    @ObservationIgnored private var installing = false
    public var isConfigured: Bool { FileManager.default.fileExists(atPath: profile.path) }
    public private(set) var summaries: [String: String] = [:]
    public private(set) var tileSummaries: [String: Steward.TileSummary] = [:]
    /// What Accord holds about a tile's own session: where to reach it, a name someone gave it
    /// there, and when it last changed.
    public struct TileRecord: Equatable, Sendable {
        public var address: String
        public var givenTitle: String?
        public var changedAt: Date?
        /// The agent record merged in from find: the participant's own address, its effective
        /// title and where that title came from, its client and its current task.
        public var agentAddress: String?
        public var title: String?
        public var titleSource: String?
        public var task: String?
        public var client: String?
    }
    public internal(set) var tileRecords: [String: TileRecord] = [:]
    /// Where a message sender lives on this board, by Accord address: a tile id for sessions bound
    /// to a Tessera tile, else "<source>:<externalId>" (e.g. claude/<session id>) for the native
    /// conversation the session reports — which is the overseer's own binding shape.
    public private(set) var senderTiles: [String: String] = [:]
    public private(set) var incidents: [[String: Any]] = []
    public private(set) var projectedSessions: [AgentAppSession] = []
    public var retainedSessionIDs: Set<String> = []
    @ObservationIgnored public var sessions: (([AgentAppSession]) -> Void)?
    @ObservationIgnored public var nativeAliases: (() -> Set<String>)?
    @ObservationIgnored public var lookback: () -> TimeInterval = { 36 * 3600 }
    @ObservationIgnored public var digests: (() -> [Steward.Digest])?
    /// Tiles that still exist on the board, hidden and minimised ones included: the
    /// closed-observation sweep never reports one of these exited.
    @ObservationIgnored public var presentTiles: (() -> Set<String>)?
    @ObservationIgnored public var paused: (() -> Bool)?
    /// The board's overseer tile: the bridge designates its Accord agent address once known.
    @ObservationIgnored public var overseerTile: (() -> String?)?
    /// One line per unsupported or failed operator call, so an old Accord is noted, not retried loudly.
    @ObservationIgnored public var logFailure: ((String) -> Void)?
    /// Test seams for the two operator writes; production leaves both nil.
    @ObservationIgnored var designateOperation: ((String) async throws -> Void)?
    @ObservationIgnored var titleOperation: (([String: Any]) async throws -> Void)?
    @ObservationIgnored public var deliver: ((String, String, String, String, Bool) -> Bool)?
    @ObservationIgnored public var questions: (([[String: Any]]) -> Void)?
    @ObservationIgnored public var notes: (([[String: Any]]) -> Void)?
    @ObservationIgnored public var noteReads: (() -> [String])?
    @ObservationIgnored public var noteRead: ((String) -> Void)?
    @ObservationIgnored public var answers: (() -> [(String, String)])?
    @ObservationIgnored private var seen: [String: String] = [:]
    @ObservationIgnored private var published: [String: Date] = [:]
    @ObservationIgnored private var records: [String: String] = [:]
    /// When Tessera's own observations were last swept for tiles closed while it was away.
    @ObservationIgnored private var lastClosedCheck: Date?
    /// Called once per incident when the closed-observation sweep is refused as unsafe.
    @ObservationIgnored public var sweepRefused: ((String) -> Void)?
    @ObservationIgnored private var sweepRefusedLogged = false
    @ObservationIgnored private var answered: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var wasPrivate: Bool?
    @ObservationIgnored private var designatedOverseer: String?
    @ObservationIgnored private var designationDenied = false
    @ObservationIgnored private let profile: URL
    @ObservationIgnored private let session: URLSession

    public init(profile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/accord/connection.json")) {
        self.profile = profile
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        session = URLSession(configuration: config)
    }
    public func start() {
        Task { await ensureInstallation() }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        self.timer = timer
        Task { await refresh() }
        RunLoop.main.add(timer, forMode: .common)
    }
    private func ensureInstallation() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let marker = home.appendingPathComponent(".config/tessera/accord-installed-v1")
        guard profile == home.appendingPathComponent(".config/accord/connection.json"),
              ProcessInfo.processInfo.environment["TESSERA_NO_AUTO_SETUP"] != "1",
              !(FileManager.default.fileExists(atPath:marker.path) && FileManager.default.fileExists(atPath:profile.path)), !installing else { return }
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tessera-cli")
        guard FileManager.default.isExecutableFile(atPath:cli.path) else { return }
        installing = true
        defer { installing = false }
        let result = await Task.detached(priority:.utility) { () -> Bool in
            let process = Process()
            process.executableURL = cli; process.arguments = ["install"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
            catch { return false }
        }.value
        setupError = result ? nil : "Accord setup needs attention. Open Settings → Agents to retry and see details."
        await refresh()
    }
    private func connection() throws -> (URL, String, String) {
        let p = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any]
        guard let endpointFile = p?["endpointFile"] as? String, let authority = p?["authority"] as? String else { throw URLError(.badURL) }
        let endpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: endpointFile))) as? [String: Any]
        guard let raw = endpoint?["coordinator"] as? String, let url = URL(string: raw), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host ?? ""), url.user == nil, url.password == nil else { throw URLError(.badURL) }
        let tokenURL = URL(fileURLWithPath: endpointFile).deletingLastPathComponent().appendingPathComponent("admin.token")
        return (url, try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), authority)
    }
    private func call(_ connection: (URL, String, String), path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: connection.0.appendingPathComponent(path))
        request.setValue("Bearer \(connection.1)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard data.count < 2 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        if status == 403,
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = envelope["error"] as? [String: Any],
           error["code"] as? String == "NOT_SHARED" {
            throw AccordRequestError.activityNotShared
        }
        guard status == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return value
    }
    private func operation(_ c: (URL, String, String), _ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        let identity = try await call(c, path: ".well-known/accord")
        guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
        return try await call(c, path: "v1/collaboration", body: ["operation": op, "args": args])
    }
    nonisolated static func fingerprint(_ digest: Steward.Digest) -> String {
        SHA256.hash(data: Data((digest.state + "\n" + (digest.detail ?? "") + "\n" + digest.text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// The `session-report` arguments for a digest. `sourceProgressAt` goes out only once the tile
    /// has been idle: for an active tile Accord's own now is the right progress time, and ours may
    /// be a fraction of a second ahead of the coordinator's clock, which it rejects.
    static func reportArgs(_ digest: Steward.Digest, key: String, nowMs: Int) -> [String: Any] {
        let state = digest.state == "needsInput" ? "waiting" : digest.state
        var args: [String: Any] = ["key": key, "source": "tessera", "externalId": digest.id,
            "title": String(digest.title.prefix(180)), "state": ["starting", "working", "idle", "waiting", "done", "failed", "exited"].contains(state) ? state : "unknown",
            "location": digest.subtitle, "detail": digest.detail ?? "", "private": false,
            "events": digest.text.isEmpty ? [] : [["key": fingerprint(digest), "kind": "observation", "text": String(digest.text.suffix(12000))]]]
        if digest.idleMinutes > 0 { args["sourceProgressAt"] = max(0, nowMs - digest.idleMinutes * 60000) }
        return args
    }

    /// Which digests this pass reports: a changed fingerprint always goes out; an unchanged one
    /// goes again once `refreshEvery` has passed so the observation stays live on Accord. Changed
    /// ones first, then the longest since their last report; the caller's budget caps the batch.
    nonisolated static func digestsToReport(_ digests: [Steward.Digest], seen: [String: String], published: [String: Date],
                                now: Date, refreshEvery: TimeInterval = 3600, limit: Int = 16) -> [Steward.Digest] {
        let changed = digests.filter { seen[$0.id] != fingerprint($0) }
        let due = digests.filter { seen[$0.id] == fingerprint($0) && now.timeIntervalSince(published[$0.id] ?? .distantPast) >= refreshEvery }
        return Array((changed + due)
            .sorted { a, b in
                let fa = seen[a.id] != fingerprint(a), fb = seen[b.id] != fingerprint(b)
                return fa != fb ? fa : (published[a.id] ?? .distantPast) < (published[b.id] ?? .distantPast)
            }
            .prefix(limit))
    }

    /// An observation of ours that Accord still considers open: neither retired nor terminal.
    /// A coordinator that predates the `terminal` field is read through the state string instead.
    nonisolated static func liveObservation(_ value: [String: Any]) -> Bool {
        guard value["source"] as? String == "tessera", value["retiredAt"] == nil else { return false }
        if let terminal = value["terminal"] as? Bool { return !terminal }
        return !["done", "failed", "exited", "cancelled"].contains(value["state"] as? String ?? "")
    }

    /// Accord observations of tiles that no longer exist here and have not ended there: tiles
    /// closed while Tessera was away. Hidden and minimised tiles still exist (presentTileIDs
    /// includes them); retired and terminal ones need no report.
    nonisolated static func closedObservations(_ own: [[String: Any]], presentTileIDs: Set<String>) -> [String] {
        own.compactMap { value in
            guard liveObservation(value), let tile = value["externalId"] as? String,
                  !presentTileIDs.contains(tile) else { return nil }
            return tile
        }
    }

    /// The sweep is refused rather than mass-report: an empty present set means the workspace
    /// didn't load (a failed restore must not retire every agent), and a missing share beyond
    /// max(5, half the live observations) is implausible for tiles genuinely closed while away.
    /// The caller logs once and retries at the next check.
    nonisolated static func closedSweepAllowed(_ own: [[String: Any]], presentTileIDs: Set<String>, missing: [String]) -> Bool {
        guard !presentTileIDs.isEmpty else { return false }
        let live = own.filter(liveObservation).count
        return missing.count <= max(5, live / 2)
    }
    public func refresh() async {
        guard !busy, FileManager.default.fileExists(atPath: profile.path) else { return }
        busy = true
        defer { busy = false }
        do {
            let c = try connection()
            let identity = try await call(c, path: ".well-known/accord")
            guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
            let privacy = paused?() == true
            if wasPrivate != privacy {
                _ = try await operation(c, "source-privacy", ["key": UUID().uuidString, "source": "tessera", "private": privacy])
                wasPrivate = privacy
                seen.removeAll()
            }
            if privacy { summaries.removeAll(); tileSummaries.removeAll(); tileRecords.removeAll(); senderTiles.removeAll(); incidents.removeAll(); projectedSessions = []; sessions?([]); connected = true; return }
            let values = digests?() ?? []
            for digest in Self.digestsToReport(values, seen: seen, published: published, now: Date()) {
                var args = Self.reportArgs(digest, key: UUID().uuidString, nowMs: Int(Date().timeIntervalSince1970 * 1000))
                var result: [String: Any]?
                do {
                    result = try await operation(c, "session-report", args)
                } catch {
                    // One rejected report must not stall the pass: try once without progress time
                    // (a coordinator a fraction behind our clock refuses progress-at-now), and if it
                    // still fails count the digest published so it returns only when it changes.
                    args.removeValue(forKey: "sourceProgressAt")
                    result = try? await operation(c, "session-report", args)
                }
                published[digest.id] = Date()
                seen[digest.id] = Self.fingerprint(digest)
                if let result { records[digest.id] = result["id"] as? String }
            }
            let current = Set(values.map(\.id))
            for tile in Array(records.keys) where !current.contains(tile) {
                do {
                    _ = try await operation(c, "session-report", ["key": UUID().uuidString, "source": "tessera", "externalId": tile,
                        "title": "Closed native session", "state": "exited"])
                    records.removeValue(forKey: tile); seen.removeValue(forKey: tile)
                } catch { continue }
            }
            let board = try await call(c, path: "v1/awareness")
            summaries = Dictionary(((board["sessions"] as? [[String: Any]]) ?? []).compactMap { value -> (String, String)? in
                guard value["source"] as? String == "tessera", let tile = value["externalId"] as? String,
                      let summary = value["summary"] as? String else { return nil }
                return (tile, summary)
            }, uniquingKeysWith: { _, latest in latest })
            tileSummaries = Dictionary(((board["sessions"] as? [[String: Any]]) ?? []).compactMap { value -> (String, Steward.TileSummary)? in
                guard value["source"] as? String == "tessera", let tile = value["externalId"] as? String, let summary = value["summary"] as? String else { return nil }
                let details = value["summaryDetails"] as? [String:Any] ?? [:]
                return (tile, Steward.TileSummary(summary:summary, blocked:details["blocked"] as? Bool ?? false, needs:details["needs"] as? String))
            }, uniquingKeysWith: { _, latest in latest })
            // The board is Accord's most recent sessions; a tile idle for days is not among them, so
            // read back all of Tessera's own. An Accord that predates `source` answers with the same recent list.
            // Accord's `list` caps at 200; with more, the most recent 200 cover the sweep.
            let own = (try? await operation(c, "sessions", ["source": "tessera", "limit": 200]))?["sessions"] as? [[String: Any]] ?? []
            let held = Self.tileRecords((board["sessions"] as? [[String: Any]] ?? []) + own, authority: c.2)
            if held != tileRecords { tileRecords = held }
            let senders = Self.senderTiles((board["sessions"] as? [[String: Any]] ?? []) + own, authority: c.2)
            if senders != senderTiles { senderTiles = senders }
            // The agent record comes from find, one participant per agent; an older Accord has
            // no `agent` object and simply yields nothing here.
            if let found = try? await operation(c, "find", ["detail": true, "local": true]),
               let participants = (found["hosts"] as? [[String: Any]])?.first?["participants"] as? [[String: Any]] {
                let agents = Self.agentByTile(participants, authority: c.2)
                var merged = tileRecords
                for (tile, record) in merged {
                    guard let match = agents[tile] else { continue }
                    var next = record, agent = match.agent
                    next.agentAddress = match.address
                    next.title = agent["title"] as? String
                    next.titleSource = agent["titleSource"] as? String
                    next.task = (agent["task"] as? String).map { String($0.prefix(80)) }
                    next.client = agent["client"] as? String
                    merged[tile] = next
                }
                if merged != tileRecords { tileRecords = merged }
                await designateOverseer(c, agents: agents)
            }
            // A tile closed while Tessera was away was never reported; its observation is still
            // live on Accord. Sweep the first pass after connecting, then every ten minutes —
            // but never on a board that looks emptied or mostly gone: that is a broken restore,
            // and reporting would retire live agents and their reservations.
            if lastClosedCheck == nil || Date().timeIntervalSince(lastClosedCheck!) >= 600 {
                lastClosedCheck = Date()
                let present = presentTiles?() ?? Set(values.map(\.id))
                let missing = Self.closedObservations(own, presentTileIDs: present)
                if Self.closedSweepAllowed(own, presentTileIDs: present, missing: missing) {
                    sweepRefusedLogged = false
                    for tile in missing {
                        _ = try? await operation(c, "session-report", ["key": UUID().uuidString, "source": "tessera", "externalId": tile,
                            "title": "Closed native session", "state": "exited"])
                    }
                } else if !sweepRefusedLogged {
                    sweepRefusedLogged = true
                    let live = own.filter(Self.liveObservation).count
                    sweepRefused?("closed-observation sweep skipped: \(missing.count) of \(live) live observations have no tile on the board")
                }
            }
            acceptSnapshot(board, nativeIDs: current.union(nativeAliases?() ?? []))
            incidents = board["incidents"] as? [[String: Any]] ?? []
            questions?(board["questions"] as? [[String: Any]] ?? [])
            for (id, answer) in answers?() ?? [] where !answered.contains(id) {
                do {
                    _ = try await operation(c, answer == "__accord_dismissed__" ? "question-dismiss" : "answer", ["key": "tessera-answer-\(id)", "id": id, "answer": answer])
                } catch {
                    let current = try await operation(c, "question", ["id": id])
                    guard ["answered", "dismissed"].contains(current["state"] as? String ?? "") else { throw error }
                }
                answered.insert(id)
            }
            let inbox = try await operation(c, "bridge-inbox", ["source": "tessera"])
            for message in (inbox["deliveries"] as? [[String: Any]]) ?? [] {
                guard let delivery = message["deliveryId"] as? String, let tile = message["externalId"] as? String,
                      let text = message["text"] as? String, let sender = message["from"] as? String,
                      let record = message["session"] as? String,
                      deliver?(delivery, tile, Self.scheduledSender(from: sender, scheduledBy: message["scheduledBy"], authority: c.2), text, message["delivery"] as? String == "native-prompt") == true else { continue }
                // Display is not read acknowledgement. The recipient acknowledges through Accord.
                _ = record
            }
            for id in noteReads?() ?? [] {
                _ = try await operation(c, "read", ["deliveryId":id])
                noteRead?(id)
            }
            let operatorInbox = try await operation(c, "inbox", [:])
            notes?(operatorInbox["messages"] as? [[String: Any]] ?? [])
            connected = true
        } catch { connectionFailed() }
    }
    public func search(_ query: String) async {
        let q = String(query.trimmingCharacters(in:.whitespacesAndNewlines).prefix(200))
        searchQuery = q; searchResults = []; searchError = nil
        guard q.count >= 2, paused?() != true else { return }
        do {
            let result = try await request("sessions",args:["query":q,"limit":50])
            guard !Task.isCancelled, searchQuery == q, paused?() != true else { return }
            let c = try connection()
            var board = result; board["authority"] = c.2
            searchResults = Self.project(board,nativeIDs:[],includeNativeHistory:true)
        } catch {
            guard !Task.isCancelled, searchQuery == q else { return }
            searchError = "Shared search unavailable; local results remain available."
        }
    }
    public func history(_ session: AgentAppSession) async throws -> AgentAppSession {
        let address = String(session.id.dropFirst(7)).split(separator:"/",maxSplits:1).map(String.init)
        guard session.id.hasPrefix("accord:"), address.count == 2 else { return session }
        let result = try await request("session-read",args:["id":address[1],"limit":100],host:address[0])
        var value = (result["session"] as? [String: Any]).flatMap { current in
            Self.project(["authority": address[0], "sessions": [current]], nativeIDs: [], includeNativeHistory: true).first
        } ?? session
        let items: [ConversationItem] = (result["events"] as? [[String:Any]] ?? []).compactMap { event in
            guard let body = event["body"] as? String else { return nil }
            return ConversationItem(id:String(describing:event["seq"] ?? UUID().uuidString),role:ConversationItem.Role(rawValue:event["kind"] as? String ?? "") ?? .system,text:Redactor.redact(body),timestamp:(event["at"] as? Double).map { Date(timeIntervalSince1970:$0/1000) })
        }
        if !items.isEmpty { value.snapshot.items = items }
        return value
    }
    public func connectHost(_ host: String) async throws -> String {
        guard MachineConfig.isValidHost(host), let executable = AccordExecutable.locate() else { throw URLError(.resourceUnavailable) }
        _ = try connection() // Never fall back to another host's default profile.
        let p = try JSONSerialization.jsonObject(with:Data(contentsOf:profile)) as? [String:Any]
        guard let path = p?["endpointFile"] as? String else { throw URLError(.badURL) }
        let data = URL(fileURLWithPath:path).deletingLastPathComponent().path
        return try await Task.detached(priority:.utility) {
            let process = Process(), output = Pipe()
            process.executableURL = executable.url
            process.arguments = executable.arguments + ["connect",host,"--data",data]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                  let authority = value["authority"] as? String else { throw URLError(.cannotConnectToHost) }
            return authority
        }.value
    }
    public func request(_ op: String, args: [String: Any] = [:], host: String? = nil) async throws -> [String: Any] {
        let c = try connection()
        let identity = try await call(c, path: ".well-known/accord")
        guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
        var body: [String: Any] = ["operation":op, "args":args]
        if let host { body["host"] = host }
        return try await call(c, path: "v1/collaboration", body: body)
    }
    public func read(_ tile: String) async throws -> String {
        let address = String(tile.dropFirst(7)).split(separator: "/", maxSplits: 1).map(String.init)
        guard address.count == 2 else { throw URLError(.badURL) }
        let c = try connection(), identity = try await call(c, path: ".well-known/accord")
        guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
        let result = try await call(c, path: "v1/collaboration", body:["operation":"session-read", "host":address[0], "args":["id":address[1]]])
        return Redactor.redact(((result["events"] as? [[String: Any]]) ?? []).map { "\($0["kind"] as? String ?? "event"): \($0["body"] as? String ?? "")" }.joined(separator:"\n"))
    }
    func connectionFailed() {
        // A transport failure is not a session exit. Preserve the last good board.
        connected = false
        lastClosedCheck = nil
        sweepRefusedLogged = false
        designationDenied = false
    }
    /// Accord's record of each tile Tessera reported to it, by tile id. Only this host's sessions
    /// count: a linked host's Tessera reports tiles of its own under the same source.
    static func tileRecords(_ sessions: [[String: Any]], authority: String) -> [String: TileRecord] {
        Dictionary(sessions.compactMap { value -> (String, TileRecord)? in
            guard value["source"] as? String == "tessera", let tile = value["externalId"] as? String,
                  let address = value["address"] as? String, address.hasPrefix(authority + "/") else { return nil }
            let given = (value["givenTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let changed = (value["progressAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return (tile, TileRecord(address: address, givenTitle: given, changedAt: changed))
        }, uniquingKeysWith: { _, latest in latest })
    }

    /// Where each local-authority session's messages come from on this board: its tile, or the
    /// native conversation its `nativeSession` binding names. Only this host's sessions count —
    /// a linked host reports tiles of its own under the same sources.
    static func senderTiles(_ sessions: [[String: Any]], authority: String) -> [String: String] {
        Dictionary(sessions.compactMap { value -> (String, String)? in
            guard let address = value["address"] as? String, address.hasPrefix(authority + "/") else { return nil }
            if value["source"] as? String == "tessera", let external = value["externalId"] as? String { return (address, external) }
            guard let binding = value["nativeSession"] as? [String: Any],
                  let source = binding["source"] as? String, let external = binding["externalId"] as? String else { return nil }
            return (address, source == "tessera" ? external : source + ":" + external)
        }, uniquingKeysWith: { _, latest in latest })
    }

    /// Each tile's agent record, by tile id: the participant Accord links to the tile with role
    /// agent (preferred), or whose mailbox binding is the tile itself. A nested CLI session only
    /// stands in for the tile when no agent does.
    static func agentByTile(_ participants: [[String: Any]], authority: String) -> [String: (address: String, agent: [String: Any])] {
        var found: [String: (address: String, agent: [String: Any])] = [:]
        for p in participants {
            guard let address = p["address"] as? String, address.hasPrefix(authority + "/"),
                  let agent = p["agent"] as? [String: Any] else { continue }
            let tile = (agent["tile"] as? [String: Any])?["id"] as? String
            let native = agent["native"] as? [String: Any]
            let linked = tile ?? ((native?["source"] as? String) == "tessera" ? native?["id"] as? String : nil)
            guard let linked else { continue }
            let role = (agent["tile"] as? [String: Any])?["role"] as? String ?? "agent"
            let existingRole = ((found[linked]?.agent["tile"] as? [String: Any])?["role"] as? String) ?? "agent"
            if existingRole == "agent", role != "agent" { continue }
            found[linked] = (address, agent)
        }
        return found
    }

    /// Whose wake policy a message answers to: a native-prompt from this host's scheduler is
    /// judged as its owner (`scheduledBy`). A scheduler from anywhere else, or a `scheduledBy`
    /// on any other sender, is never trusted — it is just the sender.
    static func scheduledSender(from: String, scheduledBy: Any?, authority: String) -> String {
        guard from == authority + "/accord-scheduler",
              let owner = scheduledBy as? String, owner.contains("/") else { return from }
        return owner
    }

    /// Once the overseer tile's agent address is known, name it Accord's designated overseer so
    /// its titles land in the overseer layer. An Accord that predates the operation answers with
    /// a failure; that is noted once and left alone.
    func designateOverseer(_ c: (URL, String, String), agents: [String: (address: String, agent: [String: Any])]) async {
        guard !designationDenied, let tile = overseerTile?(), let match = agents[tile] else { return }
        let address = match.address
        // The designated agent must be the tile's agent, not a nested session inside it.
        let role = (match.agent["tile"] as? [String: Any])?["role"] as? String ?? "agent"
        guard role == "agent" || (match.agent["tile"] == nil && (match.agent["native"] as? [String: Any])?["source"] as? String == "tessera"),
              designatedOverseer != address else { return }
        do {
            if let designateOperation { try await designateOperation(address) }
            else { _ = try await operation(c, "overseer-designate", ["key": "designate:" + address, "address": address]) }
            designatedOverseer = address
        } catch {
            designationDenied = true
            logFailure?("overseer-designate rejected; layered titles keep working without a designated overseer")
        }
    }

    /// The user's rename, sent to Accord as the operator layer of that tile's agent record, so
    /// every agent sees it on the next poll. An older Accord still accepts the name on the
    /// tile's observation, which is the fallback target.
    public func setTileTitle(_ tile: String, _ name: String) async {
        var args: [String: Any] = ["key": UUID().uuidString, "title": String(name.prefix(120))]
        if let address = tileRecords[tile]?.agentAddress?.split(separator: "/").last { args["id"] = String(address) }
        else { args["source"] = "tessera"; args["externalId"] = tile }
        if let titleOperation {
            do { try await titleOperation(args) } catch { logFailure?("session-title rejected for \(tile)") }
            return
        }
        guard let c = try? connection() else { return }
        do { _ = try await operation(c, "session-title", args) }
        catch { logFailure?("session-title rejected for \(tile)") }
    }

    func acceptSnapshot(_ board: [String:Any], nativeIDs: Set<String>, now: Date = Date()) {
        let missing = Set((board["hosts"] as? [[String:Any]] ?? []).filter { $0["status"] as? String == "unknown" }.compactMap { $0["authority"] as? String })
        let retained = projectedSessions.filter { value in
            let host = String(value.id.dropFirst(7)).split(separator:"/").first.map(String.init) ?? ""
            return missing.contains(host)
        }
        let live = Self.project(board,nativeIDs:nativeIDs,lookback:lookback(),now:now)
        let present = Set(live.map(\.id))
        let opened = Self.project(board,nativeIDs:[],includeNativeHistory:true,now:now)
            .filter { retainedSessionIDs.contains($0.id) && !present.contains($0.id) }
        projectedSessions = live + opened + retained
        sessions?(projectedSessions)
    }

    /// Shared sessions are view-only tiles. No shell command is inferred from remote text.
    static func project(_ board: [String: Any], nativeIDs: Set<String>, includeNativeHistory: Bool = false, lookback: TimeInterval = 36 * 3600, now: Date = Date()) -> [AgentAppSession] {
        let authority = board["authority"] as? String
        return ((board["sessions"] as? [[String: Any]]) ?? []).compactMap { value in
            guard value["private"] as? Bool != true, let address = value["address"] as? String,
                  let title = value["title"] as? String, let source = value["source"] as? String else { return nil }
            // Remote reservation principals mirror the owner's native session; they are not tasks.
            if !includeNativeHistory, value["originAddress"] as? String != nil || (source == "agent" && address.split(separator:"/").last?.hasPrefix("remote-") == true) { return nil }
            let local = address.split(separator: "/").first.map(String.init) == authority
            let external = value["externalId"] as? String ?? ""
            if local && ((source == "tessera" && !includeNativeHistory) || nativeIDs.contains(source + ":" + external)) { return nil }
            if !includeNativeHistory, local, let binding = value["nativeSession"] as? [String:Any],
               let source = binding["source"] as? String, let external = binding["externalId"] as? String,
               nativeIDs.contains(source == "tessera" ? external : source + ":" + external) { return nil }
            let state = value["state"] as? String ?? "unknown"
            if !includeNativeHistory {
                // Finished and failed sessions are the queue's results and failures; dead and
                // stale ones are clutter. A tile's age decides whether the result still waits.
                guard ["starting", "working", "waiting", "blocked", "done", "failed"].contains(state) else { return nil }
                let progress = (value["progressAt"] as? Double ?? 0) / 1000
                if ["starting", "working"].contains(state), now.timeIntervalSince1970 - progress > 7200 { return nil }
                // Accord keeps done and failed forever; the board only wants recent results.
                if ["done", "failed"].contains(state), now.timeIntervalSince1970 - progress > lookback { return nil }
            }
            let activity: TileActivity = state == "waiting" ? .idle : state == "blocked" ? .needsInput : state == "cancelled" ? .exited : TileActivity(rawValue: state) ?? .idle
            let at = Date(timeIntervalSince1970: (value["progressAt"] as? Double ?? 0) / 1000)
            let reported = [value["detail"] as? String, value["summary"] as? String, title].compactMap { $0 }.first { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? title
            let detail = source == "agent" ? "Agent report at \(ISO8601DateFormatter().string(from: at)): \(reported)" : reported
            let parent = value["parentSession"] as? [String:Any]
            let parentLink: String? = parent.flatMap { p in
                guard let source=p["source"] as? String, let id=p["externalId"] as? String else { return nil }
                if local { return source == "tessera" ? id : source + ":" + id }
                guard let host=address.split(separator:"/").first else { return nil }
                let digest=SHA256.hash(data:Data((source+"/"+id).utf8)).map { String(format:"%02x",$0) }.joined()
                return "accord:"+host+"/observed-"+String(digest.prefix(40))
            }
            return AgentAppSession(id: "accord:" + address, flavor: .accord, title: title,
                cwd: value["location"] as? String ?? "", openURL: nil, resumeCommand: nil,
                snapshot: ConversationSnapshot(items: [ConversationItem(id: "summary", role: .assistant, text: Redactor.redact(detail))], activity: activity, detail: detail, lastEventAt: at),
                summary: value["summary"] as? String, lastActivityAt: at, link: parentLink)
        }
    }

}
