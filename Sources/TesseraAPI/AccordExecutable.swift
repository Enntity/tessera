import Foundation

/// Prefer an existing Accord installation. A packaged app carries the same standalone
/// service and Node runtime for machines that do not already have them.
public struct AccordExecutable: Sendable {
    public let url: URL
    public let arguments: [String]
    public static func locate() -> AccordExecutable? {
        let fm = FileManager.default
        let home = URL(fileURLWithPath:NSHomeDirectory())
        let paths = ((ProcessInfo.processInfo.environment["PATH"] ?? "") + ":" + home.appendingPathComponent(".local/bin").path).split(separator:":")
        for path in paths {
            let url = URL(fileURLWithPath:String(path)).appendingPathComponent("accord")
            if fm.isExecutableFile(atPath:url.path) { return AccordExecutable(url:url, arguments:[]) }
        }
        let executable = URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let node = contents.appendingPathComponent("Helpers/node")
        let cli = contents.appendingPathComponent("Resources/Accord/src/cli.mjs")
        if fm.isExecutableFile(atPath:node.path), fm.fileExists(atPath:cli.path) {
            return AccordExecutable(url:node, arguments:[cli.path])
        }
        return nil
    }
}
