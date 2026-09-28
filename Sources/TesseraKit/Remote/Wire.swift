import Foundation

/// Messages the Mac host sends to remote clients (the iOS app). One JSON object per WebSocket frame.
public enum HostMessage: Codable, Sendable {
    case hello(HostHello)
    /// The complete, ordered tile list. Sent on connect and whenever membership or order changes.
    case tiles([TileInfo])
    /// A single tile's metadata changed.
    case tile(TileInfo)
    /// Bootstrap for a watched terminal: resize the mirror, reset it, then feed `bytes`.
    case terminalSnapshot(TerminalFrame)
    /// Live output for a watched terminal.
    case terminalData(TerminalFrame)
    case conversation(ConversationFrame)
    case usage([UsageReading])
    case launchers([LaunchPreset])
    case notice(String)
}

/// Messages a remote client sends to the host.
public enum ClientMessage: Codable, Sendable {
    case hello(ClientHello)
    /// The tiles the client is currently showing. The host streams full content only for these.
    case watch([String])
    case input(TerminalInput)
    case action(TileAction)
    case launch(LaunchRequest)
    case refreshUsage
}

public struct HostHello: Codable, Sendable {
    public var hostName: String
    public var hostId: String
    public var protocolVersion: Int
    public init(hostName: String, hostId: String, protocolVersion: Int = WireProtocol.version) {
        self.hostName = hostName
        self.hostId = hostId
        self.protocolVersion = protocolVersion
    }
}

public struct ClientHello: Codable, Sendable {
    public var deviceName: String
    public var protocolVersion: Int
    public init(deviceName: String, protocolVersion: Int = WireProtocol.version) {
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
    }
}

public struct TerminalFrame: Codable, Sendable {
    public var id: String
    public var cols: Int
    public var rows: Int
    public var bytes: Data
    public init(id: String, cols: Int, rows: Int, bytes: Data) {
        self.id = id
        self.cols = cols
        self.rows = rows
        self.bytes = bytes
    }
}

public struct ConversationFrame: Codable, Sendable {
    public var id: String
    public var snapshot: ConversationSnapshot
    public init(id: String, snapshot: ConversationSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}

public struct TerminalInput: Codable, Sendable {
    public var id: String
    public var bytes: Data
    public init(id: String, bytes: Data) {
        self.id = id
        self.bytes = bytes
    }
}

public struct TileAction: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case acknowledge, openOnHost, restart, close }
    public var id: String
    public var kind: Kind
    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct LaunchPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var command: String?
    public var flavor: AgentFlavor
    public init(name: String, command: String?, flavor: AgentFlavor) {
        self.name = name
        self.command = command
        self.flavor = flavor
    }
}

public struct LaunchRequest: Codable, Sendable {
    public var command: String?
    public var cwd: String?
    public var url: String?
    public init(command: String? = nil, cwd: String? = nil, url: String? = nil) {
        self.command = command
        self.cwd = cwd
        self.url = url
    }
}

public enum WireProtocol {
    public static let version = 1
    public static let serviceType = "_tessera._tcp"
    public static let defaultPort: UInt16 = 47_474

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
}
