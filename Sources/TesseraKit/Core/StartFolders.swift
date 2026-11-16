import Foundation

/// Where new tiles start: the folders used lately, and the folders a typed path finds.
public enum StartFolders {
    /// How many folders are remembered, and how many a typed path is answered with.
    public static let limit = 8

    /// The folders used lately with `dir` now the latest.
    public static func remembering(_ dir: String, in recent: [String]) -> [String] {
        let path = dir.standardizedPath
        return Array(([path] + recent.filter { $0 != path }).prefix(limit))
    }

    /// Whether what is typed names a folder (`~`, `~/src`, `/opt`) rather than a tile or a command.
    public static func looksLikePath(_ typed: String) -> Bool {
        typed == "~" || typed.hasPrefix("~/") || typed.hasPrefix("/")
    }

    /// The folders a typed path could mean. A folder typed in full comes first, then (after a
    /// trailing `/`) what is in it; otherwise the folders its last word begins. Hidden folders are
    /// found only by their dot. `list` names what a folder holds, nil when it isn't one.
    public static func completions(of typed: String, home: String = NSHomeDirectory(), limit: Int = limit,
                                   list: (String) -> [String]? = contents,
                                   isFolder: ((String) -> Bool)? = nil) -> [String] {
        guard looksLikePath(typed) else { return [] }
        let path = typed.hasPrefix("~") ? home + typed.dropFirst() : typed
        let whole = path.hasSuffix("/") || typed == "~"
        let parent = whole ? (path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
            : (path as NSString).deletingLastPathComponent
        let prefix = whole ? "" : (path as NSString).lastPathComponent.lowercased()
        guard let names = list(parent) else { return [] }
        var found = whole ? [parent] : []
        for name in names.sorted(by: { $0.lowercased() < $1.lowercased() }) where found.count < limit {
            guard name.lowercased().hasPrefix(prefix), name.hasPrefix(".") == prefix.hasPrefix(".") else { continue }
            let child = parent == "/" ? "/" + name : parent + "/" + name
            if isFolder?(child) ?? (list(child) != nil) { found.append(child) }
        }
        return found
    }

    /// What a folder on this Mac holds, nil when it isn't a folder (or can't be read).
    public static func contents(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// Whether `path` is a folder on this Mac (a link to one counts).
    public static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
