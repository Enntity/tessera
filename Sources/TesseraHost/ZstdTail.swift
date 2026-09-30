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
            data.append(handle.readData(ofLength: data.count))
            (decoded, consumed) = Self.decodeCompleteFrames(data)
        }
        offset += UInt64(consumed)
        return decoded.isEmpty ? nil : decoded
    }

    /// Decodes the leading complete frames of `data`; returns the output and how many input bytes
    /// they spanned. A trailing partial frame (still being written) is left for next time.
    static func decodeCompleteFrames(_ data: Data) -> (Data, Int) {
        var consumed = 0
        var output = Data()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            // Find the extent of complete frames.
            var end = 0
            while end < raw.count {
                let frame = ZSTD_findFrameCompressedSize(base + end, raw.count - end)
                if ZSTD_isError(frame) != 0 { break }
                end += frame
            }
            guard end > 0, let stream = ZSTD_createDStream() else { return }
            defer { ZSTD_freeDStream(stream) }
            ZSTD_initDStream(stream)
            var input = ZSTD_inBuffer(src: base, size: end, pos: 0)
            let chunk = ZSTD_DStreamOutSize()
            var buffer = [UInt8](repeating: 0, count: chunk)
            while input.pos < input.size {
                let result = buffer.withUnsafeMutableBytes { out -> Int in
                    var o = ZSTD_outBuffer(dst: out.baseAddress, size: chunk, pos: 0)
                    let r = ZSTD_decompressStream(stream, &o, &input)
                    if ZSTD_isError(r) == 0 { output.append(out.bindMemory(to: UInt8.self).baseAddress!, count: o.pos) }
                    return r
                }
                if ZSTD_isError(result) != 0 { return }
            }
            consumed = end
        }
        return (output, consumed)
    }
}
