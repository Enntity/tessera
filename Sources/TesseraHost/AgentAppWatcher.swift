import AppKit
import Foundation
import Observation
import TesseraKit

/// A conversation inside the Claude or Codex desktop app, surfaced as its own tile.
public struct AgentAppSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var flavor: AgentFlavor
    public var title: String
    public var cwd: String
    public var openURL: URL?
    public var bundleID: String
    /// Shell command that continues this conversation in a terminal tile.
    public var resumeCommand: String?
    public var snapshot: ConversationSnapshot
    /// The desktop app's own one-line turn summary (Claude writes these).
    public var summary: String?
    public var needsAction: String?
    public var lastActivityAt: Date
}

/// One session's latest state, observed on its own so a busy session re-renders only its tile.
@Observable
@MainActor
public final class AgentSessionTile {
    public fileprivate(set) var session: AgentAppSession

    init(_ session: AgentAppSession) { self.session = session }
}

/// Polls the desktop apps' on-disk session stores and tails their transcripts incrementally.
@Observable
@MainActor
public final class AgentAppWatcher {
    /// Changes only when sessions come or go; each tile carries its session's updates.
    public private(set) var sessions: [String: AgentSessionTile] = [:]
    public private(set) var codexRateLimits: CodexRateLimits?
    /// Sessions idle longer than this drop off the board.
    public var lookback: TimeInterval = 36 * 3600
    /// Called after a scan that changed anything.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let scanner = TranscriptScanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanning = false

    public init() {}

    public func session(_ id: String) -> AgentAppSession? { sessions[id]?.session }

    public func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer?.tolerance = 0.3
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        let lookback = self.lookback
        let scanner = self.scanner
        DispatchQueue.global(qos: .utility).async {
            let result = scanner.scan(lookback: lookback, now: Date())
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(result) }
            }
        }
    }

    /// Writes only what changed: rewriting unchanged data would re-render the whole board every scan.
    private func apply(_ result: TranscriptScanner.Result) {
        scanning = false
        var changed = false, cameOrWent = false
        var tiles = sessions
        for (id, session) in result.sessions {
            if let tile = tiles[id] {
                if tile.session != session { tile.session = session; changed = true }
            } else {
                tiles[id] = AgentSessionTile(session)
                cameOrWent = true
            }
        }
        for id in tiles.keys where result.sessions[id] == nil {
            tiles[id] = nil
            cameOrWent = true
        }
        if cameOrWent {
            sessions = tiles
            changed = true
        }
        if let limits = result.rateLimits, limits != codexRateLimits {
            codexRateLimits = limits
            changed = true
        }
        if changed { onChange?() }
    }
}

/// Background-only state: per-file parsers and read offsets.
final class TranscriptScanner: @unchecked Sendable {
    struct Result {
        var sessions: [String: AgentAppSession]
        var rateLimits: CodexRateLimits?
    }

    private enum Parser {
        case claude(ClaudeTranscriptParser)
        case codex(CodexTranscriptParser)
    }

    private final class Tail {
        var parser: Parser
        var offset: UInt64 = 0
        var remainder = Data()
        var modified: Date = .distantPast
        init(parser: Parser) { self.parser = parser }
    }

    private let fm = FileManager.default
    private let home = URL(fileURLWithPath: NSHomeDirectory())
    private var tails: [String: Tail] = [:]
    private var claudeTranscriptIndex: [String: String] = [:]
    /// Parsed session metadata and folder listings, redone only when the file or folder changes.
    private var claudeMeta: [String: (stat: FileStat, meta: [String: Any])] = [:]
    private var listings: [String: (modified: Date, names: [String])] = [:]
    private var listed: Set<String> = []
    private var dshTitles: [String: (modified: Date?, title: String?)] = [:]
    private var codexTitles: [String: String] = [:]
    private var codexIndexModified: Date = .distantPast
    private var lastRateLimitScan: Date = .distantPast
    private var rateLimits: CodexRateLimits?

    /// First read of a large transcript only looks at the end; the state we need is recent.
    static let initialTailBytes: UInt64 = 1_000_000

    /// Session ids end up in shell commands ("Continue in Terminal"), so only plain ids pass.
    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private var touched: Set<String> = []

    func scan(lookback: TimeInterval, now: Date) -> Result {
        var sessions: [String: AgentAppSession] = [:]
        touched.removeAll(keepingCapacity: true)
        listed.removeAll(keepingCapacity: true)
        for s in scanClaudeDesktop(lookback: lookback, now: now) { sessions[s.id] = s }
        for s in scanCodexDesktop(lookback: lookback, now: now) { sessions[s.id] = s }
        for s in scanDsh(lookback: lookback, now: now) { sessions[s.id] = s }
        // Drop what belongs to transcripts and folders that aged out or went away.
        for path in tails.keys where !touched.contains(path) { tails[path] = nil }
        for path in claudeMeta.keys where !touched.contains(path) { claudeMeta[path] = nil }
        for dir in listings.keys where !listed.contains(dir) { listings[dir] = nil }
        if now.timeIntervalSince(lastRateLimitScan) > 60 {
            lastRateLimitScan = now
            rateLimits = scanCodexRateLimits(now: now) ?? rateLimits
        }
        return Result(sessions: sessions, rateLimits: rateLimits)
    }

    // MARK: Claude desktop

    private func scanClaudeDesktop(lookback: TimeInterval, now: Date) -> [AgentAppSession] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [AgentAppSession] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let meta = claudeMetadata(url.path),
                  meta["isArchived"] as? Bool != true,
                  let localId = meta["sessionId"] as? String, Self.isSafeId(localId),
                  let cliId = meta["cliSessionId"] as? String, Self.isSafeId(cliId) else { continue }
            let lastMs = (meta["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
            let lastActivity = Date(timeIntervalSince1970: lastMs / 1000)
            guard now.timeIntervalSince(lastActivity) < lookback else { continue }
            guard let path = claudeTranscriptPath(cliId) else { continue }

            let tail = tails[path] ?? Tail(parser: .claude(ClaudeTranscriptParser()))
            tails[path] = tail
            advance(tail, path: path)
            guard case .claude(let parser) = tail.parser else { continue }

            var snapshot = parser.snapshot(now: now, subagentActivity: subagentActivity(path))
            let post = meta["postTurnSummary"] as? [String: Any]
            let summary = (post?["status_detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let needsAction = (post?["needs_action"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if snapshot.activity == .done {
                if let needsAction {
                    snapshot.activity = .needsInput
                    snapshot.detail = needsAction
                } else if let summary {
                    snapshot.detail = summary
                }
            }
            let cwd = meta["cwd"] as? String ?? parser.cwd ?? ""
            var components = URLComponents(string: "claude://code/continue")
            components?.queryItems = [URLQueryItem(name: "session", value: localId)]
            out.append(AgentAppSession(
                id: "claude:" + localId, flavor: .claudeDesktop,
                title: (meta["title"] as? String) ?? parser.title ?? "Claude session",
                cwd: cwd, openURL: components?.url, bundleID: "com.anthropic.claudefordesktop",
                resumeCommand: "claude --resume \(cliId) --fork-session",
                snapshot: snapshot, summary: summary, needsAction: needsAction,
                lastActivityAt: max(lastActivity, parser.lastEventAt ?? .distantPast)))
        }
        return out
    }

    private func claudeMetadata(_ path: String) -> [String: Any]? {
        touched.insert(path)
        guard let stat = FileStat(path) else { return nil }
        if let hit = claudeMeta[path], hit.stat == stat { return hit.meta }
        // Caught mid-write, a file may not parse; keep its last good contents until it does.
        guard let data = fm.contents(atPath: path),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return claudeMeta[path]?.meta }
        claudeMeta[path] = (stat, meta)
        return meta
    }

    /// A folder's entries, listed again only when the folder itself changes (an entry came or went).
    private func list(_ dir: URL) -> [String] {
        let path = dir.path
        listed.insert(path)
        guard let modified = FileStat(path)?.modified else { return [] }
        if let hit = listings[path], hit.modified == modified { return hit.names }
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        listings[path] = (modified, names)
        return names
    }

    /// Background subagents write `<session>/subagents/agent-<id>.jsonl` beside the transcript.
    private func subagentActivity(_ transcriptPath: String) -> Date? {
        let dir = URL(fileURLWithPath: String(transcriptPath.dropLast(".jsonl".count))).appendingPathComponent("subagents")
        return list(dir).filter { $0.hasSuffix(".jsonl") }
            .compactMap { FileStat(dir.appendingPathComponent($0).path)?.modified }
            .max()
    }

    private func claudeTranscriptPath(_ cliId: String) -> String? {
        if let hit = claudeTranscriptIndex[cliId], fm.fileExists(atPath: hit) { return hit }
        let projects = home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let candidate = projects.appendingPathComponent(dir).appendingPathComponent(cliId + ".jsonl").path
            if fm.fileExists(atPath: candidate) {
                claudeTranscriptIndex[cliId] = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: DeepSeek Harness (dsh)

    private final class DshTail {
        let zstd = ZstdTail()
        var parser = DshTranscriptParser()
        var remainder = ""
    }

    private var dshTails: [String: DshTail] = [:]

    static var dshHome: URL {
        if let custom = ProcessInfo.processInfo.environment["DSH_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh")
    }

    /// Each top-level dsh session with recent activity. Logs are zstd JSONL; only newly appended
    /// frames are decoded on each pass.
    private func scanDsh(lookback: TimeInterval, now: Date) -> [AgentAppSession] {
        let root = Self.dshHome.appendingPathComponent("sessions")
        var out: [AgentAppSession] = []
        var seen: Set<String> = []
        for workspace in list(root) {
            let wsURL = root.appendingPathComponent(workspace)
            for session in list(wsURL) {
                let dir = wsURL.appendingPathComponent(session)
                // A migrated session may hold several formats; the newest version is the live log.
                let logs = list(dir).filter { $0.hasPrefix("session.v") && $0.hasSuffix(".jsonl.zstd") }
                guard let log = logs.max(by: { Self.dshVersion($0) < Self.dshVersion($1) }) else { continue }
                let path = dir.appendingPathComponent(log).path
                guard let modified = FileStat(path)?.modified, now.timeIntervalSince(modified) < lookback else { continue }
                seen.insert(path)
                let tail = dshTails[path] ?? DshTail()
                dshTails[path] = tail
                if let decoded = tail.zstd.readAppended(path: path) {
                    let text = tail.remainder + String(decoding: decoded, as: UTF8.self)
                    if let last = text.lastIndex(of: "\n") {
                        tail.parser.ingest(text: String(text[..<last]))
                        tail.remainder = String(text[text.index(after: last)...])
                    } else {
                        tail.remainder = text
                    }
                }
                let parser = tail.parser
                guard let id = parser.sessionId, !parser.isDelegated, Self.isSafeId(id) else { continue }
                let snapshot = parser.snapshot(now: now)
                // Sessions that never got a message aren't worth a tile.
                guard snapshot.items.contains(where: { $0.role == .user }) else { continue }
                let title = parser.title ?? dshTitle(id)
                    ?? snapshot.items.first(where: { $0.role == .user })?.text.preview(60) ?? "DeepSeek session"
                out.append(AgentAppSession(
                    id: "dsh:" + id, flavor: .dsh, title: title, cwd: parser.cwd ?? "",
                    openURL: nil, bundleID: "", resumeCommand: nil,
                    snapshot: snapshot, summary: nil, needsAction: nil,
                    lastActivityAt: parser.lastEventAt ?? modified))
            }
        }
        for path in dshTails.keys where !seen.contains(path) { dshTails[path] = nil }
        return out
    }

    static func dshVersion(_ name: String) -> Int {
        Int(name.dropFirst("session.v".count).prefix { $0.isNumber }) ?? 0
    }

    /// dsh's projection cache holds the generated title even before it's in the log we've read.
    private func dshTitle(_ id: String) -> String? {
        let url = Self.dshHome.appendingPathComponent("storages/session_projcache/sessions/\(id).json")
        let modified = FileStat(url.path)?.modified
        if let hit = dshTitles[id], hit.modified == modified { return hit.title }
        let title = Self.dshCachedTitle(at: url)
        dshTitles[id] = (modified, title)
        return title
    }

    static func dshCachedTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = (obj["record"] as? [String: Any])?["rows"] as? [String: Any],
              let title = (rows["title"] as? [String: Any])?["val"] as? String, !title.isEmpty else { return nil }
        return title
    }

    // MARK: Codex desktop

    private func scanCodexDesktop(lookback: TimeInterval, now: Date) -> [AgentAppSession] {
        refreshCodexTitles()
        var out: [AgentAppSession] = []
        for (path, _) in CodexRollouts.recentFiles(lookback: lookback, now: now) {
            guard let head = CodexRollouts.head(path), head.isDesktop, !head.isSubagent,
                  Self.isSafeId(head.id) else { continue }
            let tail = tails[path] ?? Tail(parser: .codex(CodexTranscriptParser()))
            tails[path] = tail
            advance(tail, path: path)
            guard case .codex(let parser) = tail.parser else { continue }
            let snapshot = parser.snapshot(now: now)
            out.append(AgentAppSession(
                id: "codex:" + head.id, flavor: .codexDesktop,
                title: codexTitles[head.id] ?? snapshot.items.first(where: { $0.role == .user })?.text.preview(60) ?? "Codex thread",
                cwd: head.cwd, openURL: URL(string: "codex://threads/\(head.id)"), bundleID: "com.openai.codex",
                resumeCommand: "codex resume \(head.id)",
                snapshot: snapshot, summary: nil, needsAction: nil,
                lastActivityAt: parser.lastEventAt ?? tail.modified))
        }
        return out
    }

    private func refreshCodexTitles() {
        let path = home.appendingPathComponent(".codex/session_index.jsonl").path
        let modified = FileStat(path)?.modified ?? .distantPast
        guard modified > codexIndexModified, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        codexIndexModified = modified
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String else { continue }
            codexTitles[id] = name
        }
    }

    /// ChatGPT-plan limits are only present in sessions signed in with ChatGPT; take the newest one that has them.
    private func scanCodexRateLimits(now: Date) -> CodexRateLimits? {
        for (path, _) in CodexRollouts.recentFiles(lookback: 7 * 86_400, now: now).prefix(12) {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            var parser = CodexTranscriptParser()
            for line in text.split(separator: "\n") where line.contains("\"used_percent\"") { parser.ingest(line: line) }
            if let limits = parser.rateLimits { return limits }
        }
        return nil
    }

    // MARK: Tailing

    private func advance(_ tail: Tail, path: String) {
        touched.insert(path)
        guard let stat = FileStat(path) else { return }
        let size = stat.size, modified = stat.modified
        if size < tail.offset {
            // Truncated or replaced: start over.
            tail.offset = 0
            tail.remainder = Data()
            switch tail.parser {
            case .claude: tail.parser = .claude(ClaudeTranscriptParser())
            case .codex: tail.parser = .codex(CodexTranscriptParser())
            }
        }
        guard size > tail.offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var skipPartial = false
        if tail.offset == 0, size > Self.initialTailBytes {
            tail.offset = size - Self.initialTailBytes
            skipPartial = true
        }
        try? handle.seek(toOffset: tail.offset)
        var data = handle.readDataToEndOfFile()
        tail.offset += UInt64(data.count)
        tail.modified = modified
        if skipPartial, let nl = data.firstIndex(of: 0x0A) { data = data[(nl + 1)...] }
        var chunk = tail.remainder
        chunk.append(data)
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            tail.remainder = chunk
            return
        }
        tail.remainder = Data(chunk[(lastNewline + 1)...])
        let complete = String(decoding: chunk[..<lastNewline], as: UTF8.self)
        switch tail.parser {
        case .claude(var p):
            p.ingest(text: complete)
            tail.parser = .claude(p)
        case .codex(var p):
            p.ingest(text: complete)
            tail.parser = .codex(p)
        }
    }
}
