import Darwin
import Foundation

/// Size and modification time from a single `stat` — cheaper than FileManager's attributes, which
/// also read extended attributes.
struct FileStat: Equatable {
    var size: UInt64
    var modified: Date

    init?(_ path: String) {
        var s = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &s, 0) == 0 else { return nil }
        size = UInt64(s.st_size)
        modified = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec) + TimeInterval(s.st_mtimespec.tv_nsec) / 1e9)
    }
}
