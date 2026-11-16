import Foundation
import TesseraKit

/// One JSONL transcript read a little at a time: what was there on the first read is taken from
/// its last megabyte, later reads take only what was appended, and a file that shrank (truncated
/// or replaced) is started over. The file's own state lives here, so anything that watches a
/// transcript — the agent-app watcher, the overseer's chat — reads it the same way.
final class TranscriptTail: @unchecked Sendable {
    enum Parser {
        case claude(ClaudeTranscriptParser)
        case codex(CodexTranscriptParser)
    }

    var parser: Parser
    var offset: UInt64 = 0
    var remainder = Data()
    var modified: Date = .distantPast

    init(parser: Parser) { self.parser = parser }

    static let initialTailBytes: UInt64 = 1_000_000

    /// Reads what is new in `path` into the parser. False when the file isn't there (nothing lost:
    /// the next advance picks it up once it appears).
    @discardableResult
    func advance(path: String) -> Bool {
        guard let stat = FileStat(path) else { return false }
        let size = stat.size, modified = stat.modified
        if size < offset {
            // Truncated or replaced: start over.
            offset = 0
            remainder = Data()
            switch parser {
            case .claude: parser = .claude(ClaudeTranscriptParser())
            case .codex: parser = .codex(CodexTranscriptParser())
            }
        }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        var skipPartial = false
        if offset == 0, size > Self.initialTailBytes {
            offset = size - Self.initialTailBytes
            skipPartial = true
        }
        try? handle.seek(toOffset: offset)
        var data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        self.modified = modified
        if skipPartial, let nl = data.firstIndex(of: 0x0A) { data = data[(nl + 1)...] }
        var chunk = remainder
        chunk.append(data)
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
            remainder = chunk
            return true
        }
        remainder = Data(chunk[(lastNewline + 1)...])
        let complete = String(decoding: chunk[..<lastNewline], as: UTF8.self)
        switch parser {
        case .claude(var p):
            p.ingest(text: complete)
            parser = .claude(p)
        case .codex(var p):
            p.ingest(text: complete)
            parser = .codex(p)
        }
        return true
    }
}
