import Foundation
import Darwin

/// Where a running Tessera listens for agents on this Mac, and the token they must show. Tessera
/// writes it (readable by this user only) when its agent API starts; the `tessera` command reads it.
public struct AgentEndpoint: Codable, Equatable, Sendable {
    public var port: UInt16
    public var token: String
    /// The Tessera process serving it, so a file left behind by a crash is told apart.
    public var pid: Int32
    public var version: Int

    public static let currentVersion = 1
    public static let fileName = "agent-api.json"

    public init(port: UInt16, token: String, pid: Int32, version: Int = Self.currentVersion) {
        self.port = port
        self.token = token
        self.pid = pid
        self.version = version
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)/rpc")! }

    /// Tessera's data folder: `TESSERA_DATA_DIR` (a development copy), else Application Support.
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["TESSERA_DATA_DIR"], !override.isEmpty { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tessera")
    }

    public static func file(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    public static func read(from directory: URL = dataDirectory()) -> AgentEndpoint? {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
        return try? JSONDecoder().decode(AgentEndpoint.self, from: data)
    }

    /// Written atomically and readable by this user only: the token is a credential.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Self.file(in: directory)
        let temporary = directory.appendingPathComponent(".agent-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Restrict permissions at creation, before any credential bytes become visible.
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(self),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func remove(from directory: URL, ifPid pid: Int32) {
        if read(from: directory)?.pid == pid { try? FileManager.default.removeItem(at: file(in: directory)) }
    }
}

/// Who is calling: what the `tessera` command knows about the agent that ran it. Sent with every
/// call (in the request's `_meta`), and used to work out which tile the agent is.
public struct AgentCaller: Codable, Equatable, Sendable {
    /// `TESSERA_TILE_ID`, which every terminal Tessera starts carries.
    public var tile: String?
    public var cwd: String?
    /// A name the agent gives itself (`--as`, `TESSERA_AS`), for when no tile can be found.
    public var name: String?

    public init(tile: String? = nil, cwd: String? = nil, name: String? = nil) {
        self.tile = tile
        self.cwd = cwd
        self.name = name
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment, name: String? = nil) -> AgentCaller {
        AgentCaller(tile: environment["TESSERA_TILE_ID"].flatMap { $0.isEmpty ? nil : $0 },
                    cwd: FileManager.default.currentDirectoryPath,
                    name: name ?? environment["TESSERA_AS"].flatMap { $0.isEmpty ? nil : $0 })
    }
}
