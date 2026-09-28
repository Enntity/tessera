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

/// Polls the desktop apps' on-disk session stores and tails their transcripts incrementally.
@Observable
@MainActor
public final class AgentAppWatcher {
    public private(set) var sessions: [String: AgentAppSession] = [:]
    public private(set) var codexRateLimits: CodexRateLimits?
    /// Sessions idle longer than this drop off the board.
    public var lookback: TimeInterval = 36 * 3600

    @ObservationIgnored private let scanner = TranscriptScanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanning = false

    public init() {}

    public func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    // Reassigning unchanged data would re-render the whole board every scan.
                    if self.sessions != result.sessions { self.sessions = result.sessions }
                    if let limits = result.rateLimits, limits != self.codexRateLimits { self.codexRateLimits = limits }
                }
            }
        }
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
    private var codexHeads: [String: CodexRolloutHead] = [:]
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
        for s in scanClaudeDesktop(lookback: lookback, now: now) { sessions[s.id] = s }
        for s in scanCodexDesktop(lookback: lookback, now: now) { sessions[s.id] = s }
        // Drop parsers for transcripts that aged out.
        for path in tails.keys where !touched.contains(path) { tails[path] = nil }
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
            guard let data = try? Data(contentsOf: url),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
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

            var snapshot = parser.snapshot(now: now)
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

    // MARK: Codex desktop

    private func scanCodexDesktop(lookback: TimeInterval, now: Date) -> [AgentAppSession] {
        refreshCodexTitles()
        var out: [AgentAppSession] = []
        for (path, _) in CodexRollouts.recentFiles(lookback: lookback, now: now) {
            guard let head = codexHead(path), head.isDesktop, !head.isSubagent,
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

    private func codexHead(_ path: String) -> CodexRolloutHead? {
        if let hit = codexHeads[path] { return hit }
        guard let head = CodexRollouts.readHead(path) else { return nil }
        codexHeads[path] = head
        return head
    }

    private func refreshCodexTitles() {
        let path = home.appendingPathComponent(".codex/session_index.jsonl").path
        let modified = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
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
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        let modified = attrs[.modificationDate] as? Date ?? Date()
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
