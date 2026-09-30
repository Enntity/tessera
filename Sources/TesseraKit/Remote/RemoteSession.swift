import Foundation
import Network
import Observation

/// A Mac the user has paired with.
public struct PairedHost: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name + "@" + (address ?? "bonjour") }
    public var name: String
    /// Hostname / IP for direct connections (LAN, Tailscale). Nil means resolve `name` via Bonjour.
    public var address: String?
    public var port: UInt16

    public init(name: String, address: String?, port: UInt16 = WireProtocol.defaultPort) {
        self.name = name
        self.address = address
        self.port = port
    }

    public var endpoint: NWEndpoint {
        if let address, let p = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(address), port: p)
        }
        return .service(name: name, type: WireProtocol.serviceType, domain: "local.", interface: nil)
    }

    /// Parses `tessera://pair?host=…&port=…&code=…&name=…`; returns the host and its pairing code.
    public static func fromPairingURL(_ url: URL) -> (PairedHost, String)? {
        guard url.scheme == "tessera", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let code = value("code"), let name = value("name") else { return nil }
        let port = value("port").flatMap(UInt16.init) ?? WireProtocol.defaultPort
        return (PairedHost(name: name, address: value("host"), port: port), code)
    }
}

/// The client side of the protocol: mirrors the host's board, streams the tiles on screen, and
/// sends keystrokes and actions back.
@Observable
@MainActor
public final class RemoteSession {
    public enum State: Equatable, Sendable {
        case idle, connecting, connected, failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var host: PairedHost?
    public private(set) var hostName: String?
    public private(set) var tiles: [TileInfo] = []
    public private(set) var conversations: [String: ConversationSnapshot] = [:]
    public private(set) var usage: [UsageReading] = []
    public private(set) var launchers: [LaunchPreset] = []
    public private(set) var notice: String?
    /// Terminal mirrors, fed by snapshots and live data for watched tiles. This changes only when a
    /// mirror comes or goes; each mirror's own revision drives its redraws.
    public private(set) var mirrors: [String: TerminalMirror] = [:]

    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var visibility: [String: Int] = [:]
    @ObservationIgnored private var retry = 0
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored private let deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// What waits on the user, in the order the Mac's ⌘J visits it.
    public var attentionTiles: [TileInfo] { tiles.attentionQueue() }

    public func connect(to host: PairedHost, code: String) {
        disconnect()
        self.host = host
        self.code = code
        wantConnected = true
        open()
    }

    public func disconnect() {
        wantConnected = false
        connection?.cancel()
        connection = nil
        state = .idle
    }

    /// Call when the app returns to the foreground.
    public func resume() {
        guard wantConnected, state != .connected, state != .connecting else { return }
        open()
    }

    private func open() {
        guard let host else { return }
        connection?.cancel()
        state = .connecting
        let c = NWConnection(to: host.endpoint, using: SecureChannel.parameters(pairingCode: code))
        connection = c
        c.stateUpdateHandler = { [weak self] s in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === c else { return }
                    switch s {
                    case .ready:
                        self.retry = 0
                        self.send(.hello(ClientHello(deviceName: self.deviceName)))
                        self.resendWatch()
                    case .failed(let e):
                        self.connectionLost(e.localizedDescription)
                    case .waiting(let e):
                        self.state = .failed(Self.explain(e))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
        }
        c.start(queue: .main)
        SecureChannel.receiveFrames(on: c, handler: { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }, onEnd: { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === c else { return }
                    self.connectionLost(error.map(Self.explain) ?? "Disconnected")
                }
            }
        })
    }

    private static func explain(_ e: NWError) -> String {
        if case .tls = e { return "Pairing code rejected" }
        return e.localizedDescription
    }

    private func connectionLost(_ why: String) {
        connection?.cancel()
        connection = nil
        state = .failed(why)
        guard wantConnected else { return }
        retry += 1
        let delay = min(15, pow(1.6, Double(retry)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantConnected, self.connection == nil else { return }
                self.open()
            }
        }
    }

    // MARK: Sending

    public func send(_ message: ClientMessage) {
        guard let connection, let data = try? WireProtocol.encode(message) else { return }
        SecureChannel.sendFrame(data, on: connection)
    }

    public func type(_ text: String, into id: String) {
        send(.input(TerminalInput(id: id, bytes: Data(Self.undoSmartPunctuation(text).utf8))))
    }

    /// Phone keyboards "improve" quotes and dashes, which breaks shell commands.
    nonisolated public static func undoSmartPunctuation(_ text: String) -> String {
        var out = text
        for (fancy, plain) in [("“", "\""), ("”", "\""), ("„", "\""), ("‘", "'"), ("’", "'"), ("—", "--"), ("–", "-"), ("…", "...")] {
            out = out.replacingOccurrences(of: fancy, with: plain)
        }
        return out
    }

    public func key(_ key: TerminalKey, into id: String) {
        let appCursor = mirrors[id]?.terminal.applicationCursor ?? false
        send(.input(TerminalInput(id: id, bytes: Data(key.bytes(applicationCursor: appCursor)))))
    }

    public func action(_ kind: TileAction.Kind, on id: String) {
        send(.action(TileAction(id: id, kind: kind)))
    }

    /// Views report what is on screen; the host streams content only for those tiles.
    public func setVisible(_ id: String, _ visible: Bool) {
        visibility[id, default: 0] += visible ? 1 : -1
        if visibility[id, default: 0] <= 0 { visibility[id] = nil }
        let next = Set(visibility.keys)
        guard next != watched else { return }
        watched = next
        resendWatch()
    }

    private func resendWatch() {
        send(.watch(Array(watched)))
    }

    // MARK: Receiving

    private func receive(_ data: Data) {
        guard let message = try? WireProtocol.decode(HostMessage.self, from: data) else {
            // Something this build can't read: say so rather than quietly showing stale tiles.
            let update = "This Mac runs a newer Tessera; update the app to see everything."
            if notice != update { notice = update }
            return
        }
        switch message {
        case .hello(let h):
            hostName = h.hostName
            notice = nil
            state = .connected
        case .tiles(let list):
            tiles = list
            let ids = Set(list.map(\.id))
            for id in mirrors.keys where !ids.contains(id) { mirrors[id] = nil }
        case .tile(let info):
            if let i = tiles.firstIndex(where: { $0.id == info.id }) { tiles[i] = info }
        case .terminalSnapshot(let f):
            if mirrors[f.id] == nil { mirrors[f.id] = TerminalMirror(cols: f.cols, rows: f.rows) }
            mirrors[f.id]?.reset(cols: f.cols, rows: f.rows, bytes: [UInt8](f.bytes))
        case .terminalData(let f):
            mirrors[f.id]?.feed([UInt8](f.bytes), cols: f.cols, rows: f.rows)
        case .conversation(let c):
            conversations[c.id] = c.snapshot
        case .usage(let readings):
            usage = readings
        case .launchers(let list):
            launchers = list
        case .notice(let text):
            notice = text
            // A notice before hello means the host refused us (e.g. version mismatch); retrying won't help.
            if hostName == nil {
                wantConnected = false
                state = .failed(text)
            }
        }
    }
}

/// Keys a phone keyboard can't type, encoded the way terminals expect.
public enum TerminalKey: String, CaseIterable, Sendable {
    case escape, tab, enter, ctrlC, ctrlD, up, down, left, right, backspace

    public var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .enter: "⏎"
        case .ctrlC: "^C"
        case .ctrlD: "^D"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .backspace: "⌫"
        }
    }

    public func bytes(applicationCursor: Bool) -> [UInt8] {
        let csi: [UInt8] = applicationCursor ? [0x1B, 0x4F] : [0x1B, 0x5B]
        switch self {
        case .escape: return [0x1B]
        case .tab: return [0x09]
        case .enter: return [0x0D]
        case .ctrlC: return [0x03]
        case .ctrlD: return [0x04]
        case .backspace: return [0x7F]
        case .up: return csi + [0x41]
        case .down: return csi + [0x42]
        case .right: return csi + [0x43]
        case .left: return csi + [0x44]
        }
    }
}
