// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Observation
import TesseraKit
import TesseraAPI

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
    public private(set) var incidents: [[String: Any]] = []
    @ObservationIgnored public var sessions: (([AgentAppSession]) -> Void)?
    @ObservationIgnored public var digests: (() -> [Steward.Digest])?
    @ObservationIgnored public var paused: (() -> Bool)?
    @ObservationIgnored public var deliver: ((String, String, String, String, Bool) -> Bool)?
    @ObservationIgnored public var questions: (([[String: Any]]) -> Void)?
    @ObservationIgnored public var notes: (([[String: Any]]) -> Void)?
    @ObservationIgnored public var noteReads: (() -> [String])?
    @ObservationIgnored public var noteRead: ((String) -> Void)?
    @ObservationIgnored public var answers: (() -> [(String, String)])?
    @ObservationIgnored private var seen: [String: String] = [:]
    @ObservationIgnored private var published: [String: Date] = [:]
    @ObservationIgnored private var records: [String: String] = [:]
    @ObservationIgnored private var answered: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var wasPrivate: Bool?
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
              !FileManager.default.fileExists(atPath:marker.path), !installing else { return }
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
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return value
    }
    private func operation(_ c: (URL, String, String), _ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        let identity = try await call(c, path: ".well-known/accord")
        guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
        return try await call(c, path: "v1/collaboration", body: ["operation": op, "args": args])
    }
    private func fingerprint(_ digest: Steward.Digest) -> String {
        SHA256.hash(data: Data((digest.state + "\n" + (digest.detail ?? "") + "\n" + digest.text).utf8)).map { String(format: "%02x", $0) }.joined()
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
            if privacy { summaries.removeAll(); tileSummaries.removeAll(); incidents.removeAll(); sessions?([]); connected = true; return }
            let values = digests?() ?? []
            for digest in values.filter({ seen[$0.id] != fingerprint($0) }).sorted(by: { (published[$0.id] ?? .distantPast) < (published[$1.id] ?? .distantPast) }).prefix(16) {
                let state = digest.state == "needsInput" ? "waiting" : digest.state
                let result = try await operation(c, "session-report", ["key": UUID().uuidString, "source": "tessera", "externalId": digest.id,
                    "title": String(digest.title.prefix(180)), "state": ["starting", "working", "idle", "waiting", "done", "failed", "exited"].contains(state) ? state : "unknown",
                    "location": digest.subtitle, "detail": digest.detail ?? "", "private": false,
                    "sourceProgressAt": max(0, Int(Date().timeIntervalSince1970 * 1000) - digest.idleMinutes * 60000),
                    "events": digest.text.isEmpty ? [] : [["key": fingerprint(digest), "kind": "observation", "text": String(digest.text.suffix(12000))]]])
                published[digest.id] = Date()
                seen[digest.id] = fingerprint(digest)
                records[digest.id] = result["id"] as? String
            }
            let current = Set(values.map(\.id))
            for tile in Array(records.keys) where !current.contains(tile) {
                _ = try await operation(c, "session-report", ["key": UUID().uuidString, "source": "tessera", "externalId": tile,
                    "title": "Closed native session", "state": "exited"])
                records.removeValue(forKey: tile); seen.removeValue(forKey: tile)
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
            sessions?(Self.project(board, nativeIDs: current) + Self.projectIncidents(board,nativeIDs:current))
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
                      let record = message["session"] as? String, deliver?(delivery, tile, sender, text, message["delivery"] as? String == "native-prompt") == true else { continue }
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
        } catch { connected = false; summaries.removeAll(); tileSummaries.removeAll(); incidents.removeAll(); sessions?([]) }
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
        var value = session
        value.snapshot.items = (result["events"] as? [[String:Any]] ?? []).compactMap { event in
            guard let body = event["body"] as? String else { return nil }
            return ConversationItem(id:String(describing:event["seq"] ?? UUID().uuidString),role:ConversationItem.Role(rawValue:event["kind"] as? String ?? "") ?? .system,text:Redactor.redact(body),timestamp:(event["at"] as? Double).map { Date(timeIntervalSince1970:$0/1000) })
        }
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
    static func projectIncidents(_ board: [String:Any], nativeIDs: Set<String>) -> [AgentAppSession] {
        let views = board["sessions"] as? [[String:Any]] ?? []
        return (board["incidents"] as? [[String:Any]] ?? []).compactMap { incident in
            guard incident["state"] as? String == "open", let id = incident["id"] as? String,
                  let subject = incident["session_id"] as? String,
                  let view = views.first(where: { $0["id"] as? String == subject }), view["private"] as? Bool != true else { return nil }
            let evidence = incident["evidence"] as? [String:Any] ?? [:]
            let detail: String
            switch evidence["kind"] as? String {
            case "quiet-session": detail = "No meaningful progress reported for \((evidence["quietMs"] as? Int ?? 0) / 60000) minutes. Accord has requested a check-in."
            case "idle-resource": detail = "The reserved resource looks idle. Accord has asked its holder to check in; ownership has not changed."
            default: detail = Redactor.redact(evidence["reason"] as? String ?? "Accord has requested a check-in.")
            }
            let source = view["source"] as? String ?? "", external = view["externalId"] as? String ?? ""
            let native = source == "tessera" ? external : source + ":" + external
            let link = nativeIDs.contains(native) ? native : (view["address"] as? String).map { "accord:" + $0 }
            let at = Date(timeIntervalSince1970:(incident["updated_at"] as? Double ?? 0)/1000)
            return AgentAppSession(id:"overseer:"+id,flavor:.accord,title:"Check-in: " + (view["title"] as? String ?? "Session"),cwd:"Accord overseer",openURL:nil,resumeCommand:nil,
                // The overseer is asking the agent, not the operator. Keep its evidence visible
                // without manufacturing a human question; real questions use Accord's inbox.
                snapshot:ConversationSnapshot(items:[ConversationItem(id:id,role:.system,text:detail)],activity:.idle,detail:detail,lastEventAt:at),summary:detail,lastActivityAt:at,link:link)
        }
    }

    /// Shared sessions are view-only tiles. No shell command is inferred from remote text.
    static func project(_ board: [String: Any], nativeIDs: Set<String>, includeNativeHistory: Bool = false) -> [AgentAppSession] {
        let authority = board["authority"] as? String
        return ((board["sessions"] as? [[String: Any]]) ?? []).compactMap { value in
            guard value["private"] as? Bool != true, let address = value["address"] as? String,
                  let title = value["title"] as? String, let source = value["source"] as? String else { return nil }
            let local = address.split(separator: "/").first.map(String.init) == authority
            let external = value["externalId"] as? String ?? ""
            if local && ((source == "tessera" && !includeNativeHistory) || nativeIDs.contains(source + ":" + external)) { return nil }
            let state = value["state"] as? String ?? "unknown"
            let activity: TileActivity = state == "waiting" || state == "blocked" ? .needsInput : state == "cancelled" ? .exited : TileActivity(rawValue: state) ?? .idle
            let at = Date(timeIntervalSince1970: (value["progressAt"] as? Double ?? 0) / 1000)
            let detail = value["detail"] as? String ?? ""
            return AgentAppSession(id: "accord:" + address, flavor: .accord, title: title,
                cwd: value["location"] as? String ?? "", openURL: nil, resumeCommand: nil,
                snapshot: ConversationSnapshot(items: [ConversationItem(id: "summary", role: .system, text: detail)], activity: activity, detail: detail, lastEventAt: at),
                summary: value["summary"] as? String, lastActivityAt: at)
        }
    }

}
