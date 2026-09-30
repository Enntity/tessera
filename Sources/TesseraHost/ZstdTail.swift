import Foundation
import libzstd

/// Follows a growing file of concatenated zstd frames (how dsh writes its session logs), decoding
/// only complete frames that were appended since the last read.
final class ZstdTail {
    private(set) var offset: UInt64 = 0

    /// Newly decoded bytes, or nil if nothing complete was added. A file that shrank restarts.
    /// Reads at most about `limit` compressed bytes, so a long log's first read comes in pieces
    /// instead of all at once (decoded, it's many times larger); call again for the rest.
    func readAppended(path: String, limit: Int = 1 << 20) -> Data? {
        guard let size = FileStat(path)?.size else { return nil }
        if size < offset { offset = 0 }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var data = handle.readData(ofLength: limit)
        var (decoded, consumed) = Self.decodeCompleteFrames(data)
        // A frame bigger than what was read: read on until it completes (or the file ends).
        while consumed == 0, !data.isEmpty, UInt64(data.count) < size - offset {
            let more = handle.readData(ofLength: data.count)
            if more.isEmpty { break }  // cut short under us
            data.append(more)
            (decoded, consumed) = Self.decodeCompleteFrames(data)
        }
        offset += UInt64(consumed)
        return decoded.isEmpty ? nil : decoded
    }

    /// Decodes the leading complete frames of `data`, one at a time; returns the output and how many
    /// input bytes they spanned. A trailing partial frame (still being written) is left for next
    /// time. A damaged frame is skipped whole, so it can neither repeat what came before it nor
    /// stall what comes after.
    static func decodeCompleteFrames(_ data: Data) -> (Data, Int) {
        var consumed = 0
        var output = Data()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, let stream = ZSTD_createDStream() else { return }
            defer { ZSTD_freeDStream(stream) }
            var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
            while consumed < raw.count {
                let size = ZSTD_findFrameCompressedSize(base + consumed, raw.count - consumed)
                if ZSTD_isError(size) != 0 {
                    // Not a whole frame: one still being written, unless another frame follows it.
                    guard let next = nextFrame(in: data, after: consumed) else { return }
                    consumed = next
                    continue
                }
                ZSTD_initDStream(stream)
                var input = ZSTD_inBuffer(src: base + consumed, size: size, pos: 0)
                var frame = Data()
                var result = 1
                // A frame is done when the decoder says so (0); an error, or no progress, means damage.
                while result != 0 {
                    let before = (input.pos, frame.count)
                    result = buffer.withUnsafeMutableBytes { out -> Int in
                        var o = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
                        let r = ZSTD_decompressStream(stream, &o, &input)
                        if ZSTD_isError(r) == 0 { frame.append(out.bindMemory(to: UInt8.self).baseAddress!, count: o.pos) }
                        return r
                    }
                    if ZSTD_isError(result) != 0 || before == (input.pos, frame.count) { frame = Data(); break }
                }
                output.append(frame)
                consumed += size
            }
        }
        return (output, consumed)
    }

    /// Where the next frame starts after `offset` (its magic number, 0xFD2FB528 little-endian).
    private static func nextFrame(in data: Data, after offset: Int) -> Int? {
        let from = data.startIndex + offset + 1
        guard from < data.endIndex else { return nil }
        return data.range(of: Data([0x28, 0xB5, 0x2F, 0xFD]), in: from..<data.endIndex).map { $0.lowerBound - data.startIndex }
    }
}
