// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Observation
import TesseraKit

/// Native observations and delivery remain here; shared state/search/monitoring live in Accord.
/// No Accord installation is required for Tessera's existing standalone mode.
@Observable @MainActor
public final class AccordBridge {
    public private(set) var connected = false
    public var isConfigured: Bool { FileManager.default.fileExists(atPath: profile.path) }
    public private(set) var summaries: [String: String] = [:]
    public private(set) var incidents: [[String: Any]] = []
    @ObservationIgnored public var sessions: (([AgentAppSession]) -> Void)?
    @ObservationIgnored public var digests: (() -> [Steward.Digest])?
    @ObservationIgnored public var paused: (() -> Bool)?
    @ObservationIgnored public var deliver: ((String, String, String, String, Bool) -> Bool)?
    @ObservationIgnored public var questions: (([[String: Any]]) -> Void)?
    @ObservationIgnored public var answers: (() -> [(String, String)])?
    @ObservationIgnored private var seen: [String: String] = [:]
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
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
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
            if privacy { summaries.removeAll(); incidents.removeAll(); sessions?([]); connected = true; return }
            let values = digests?() ?? []
            for digest in values.filter({ seen[$0.id] != fingerprint($0) }).prefix(16) {
                let state = digest.state == "needsInput" ? "waiting" : digest.state
                let result = try await operation(c, "session-report", ["key": UUID().uuidString, "source": "tessera", "externalId": digest.id,
                    "title": String(digest.title.prefix(180)), "state": ["starting", "working", "idle", "waiting", "done", "failed", "exited"].contains(state) ? state : "unknown",
                    "location": digest.subtitle, "detail": digest.detail ?? "", "private": false,
                    "sourceProgressAt": max(0, Int(Date().timeIntervalSince1970 * 1000) - digest.idleMinutes * 60000),
                    "events": digest.text.isEmpty ? [] : [["key": fingerprint(digest), "kind": "observation", "text": String(digest.text.suffix(12000))]]])
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
                guard value["source"] as? String == "tessera", value["summaryKind"] as? String == "model", let tile = value["externalId"] as? String,
                      let summary = value["summary"] as? String else { return nil }
                return (tile, summary)
            }, uniquingKeysWith: { _, latest in latest })
            sessions?(Self.project(board, nativeIDs: current))
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
                      let record = message["session"] as? String, deliver?(delivery, tile, sender, text, message["kind"] as? String == "notification") == true else { continue }
                _ = try await operation(c, "bridge-read", ["session": record, "deliveryId": delivery])
            }
            connected = true
        } catch { connected = false; summaries.removeAll(); incidents.removeAll(); sessions?([]) }
    }
    public func send(from tile: String, to target: String, text: String, type: Bool) async throws -> [String: Any] {
        let c = try connection()
        if records[tile] == nil || (!target.hasPrefix("accord:") && records[target] == nil) { await refresh() }
        guard records[tile] != nil else { throw URLError(.resourceUnavailable) }
        let address: String
        if target.hasPrefix("accord:") { address = String(target.dropFirst(7)) }
        else if let record = records[target] { address = c.2 + "/" + record }
        else { throw URLError(.resourceUnavailable) }
        return try await operation(c, "bridge-send", ["key": UUID().uuidString, "source":"tessera", "externalId":tile,
            "to":address, "text":Redactor.redact(text), "kind":type ? "notification" : "message"])
    }
    public func ask(from tile: String, question: String, options: [String]) async throws -> String {
        if records[tile] == nil { await refresh() }
        guard records[tile] != nil else { throw URLError(.resourceUnavailable) }
        let result = try await operation(connection(), "bridge-ask", ["key":UUID().uuidString, "source":"tessera", "externalId":tile,
            "question":Redactor.redact(question), "options":options])
        guard let id = result["id"] as? String else { throw URLError(.badServerResponse) }
        return "accord:" + id
    }
    public func read(_ tile: String) async throws -> String {
        let address = String(tile.dropFirst(7)).split(separator: "/", maxSplits: 1).map(String.init)
        guard address.count == 2 else { throw URLError(.badURL) }
        let c = try connection(), identity = try await call(c, path: ".well-known/accord")
        guard identity["authority"] as? String == c.2 else { throw URLError(.userAuthenticationRequired) }
        let result = try await call(c, path: "v1/collaboration", body:["operation":"session-read", "host":address[0], "args":["id":address[1]]])
        return Redactor.redact(((result["events"] as? [[String: Any]]) ?? []).map { "\($0["kind"] as? String ?? "event"): \($0["body"] as? String ?? "")" }.joined(separator:"\n"))
    }
    public func question(_ id: String) async throws -> [String: Any] {
        try await operation(connection(), "question", ["id":String(id.dropFirst(7))])
    }

    /// Shared sessions are view-only tiles. No shell command is inferred from remote text.
    static func project(_ board: [String: Any], nativeIDs: Set<String>) -> [AgentAppSession] {
        let authority = board["authority"] as? String
        return ((board["sessions"] as? [[String: Any]]) ?? []).compactMap { value in
            guard value["private"] as? Bool != true, let address = value["address"] as? String,
                  let title = value["title"] as? String, let source = value["source"] as? String else { return nil }
            let local = address.split(separator: "/").first.map(String.init) == authority
            let external = value["externalId"] as? String ?? ""
            if local && (source == "tessera" || nativeIDs.contains(source + ":" + external)) { return nil }
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
