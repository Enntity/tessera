import AppKit
import Foundation
import Network
import Observation
import TesseraKit

/// Serves the board to paired devices (the iOS app). Off until the user turns it on; every
/// connection must know the pairing code, which keys the TLS channel.
@Observable
@MainActor
public final class HostServer {
    public private(set) var isRunning = false
    public private(set) var status = "Off"
    public private(set) var clientNames: [String] = []
    public private(set) var pairingCode: String
    public let port: UInt16 = WireProtocol.defaultPort
    public let hostName = Host.current().localizedName ?? "Mac"

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [UUID: RemoteClient] = [:]
    @ObservationIgnored private var pump: Timer?
    @ObservationIgnored private var lastUsage: [UsageReading] = []
    @ObservationIgnored private let hostId: String

    public init(workspace: Workspace) {
        self.workspace = workspace
        if let saved = Keychain.get(account: "pairing-code") {
            pairingCode = saved
        } else {
            let fresh = SecureChannel.makePairingCode()
            Keychain.set(fresh, account: "pairing-code")
            pairingCode = fresh
        }
        if let id = UserDefaults.standard.string(forKey: "tessera.hostId") {
            hostId = id
        } else {
            hostId = UUID().uuidString
            UserDefaults.standard.set(hostId, forKey: "tessera.hostId")
        }
        workspace.onTilesChanged = { [weak self] in self?.broadcastTiles() }
    }

    public var pairingURL: URL? {
        let address = Self.lanAddress() ?? ProcessInfo.processInfo.hostName
        return SecureChannel.pairingURL(host: address, port: port, code: pairingCode, name: hostName)
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: SecureChannel.parameters(pairingCode: pairingCode), on: NWEndpoint.Port(rawValue: port)!)
            l.service = NWListener.Service(name: hostName, type: WireProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch state {
                        case .ready: self.status = "Listening on :\(self.port)"; self.isRunning = true
                        case .failed(let e): self.status = "Failed: \(e.localizedDescription)"; self.stop()
                        case .cancelled: self.status = "Off"; self.isRunning = false
                        default: break
                        }
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
            }
            l.start(queue: .main)
            listener = l
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pump = timer
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        pump?.invalidate()
        pump = nil
        for c in clients.values { c.close() }
        clients.removeAll()
        clientNames = []
        isRunning = false
    }

    public func regenerateCode() {
        pairingCode = SecureChannel.makePairingCode()
        Keychain.set(pairingCode, account: "pairing-code")
        if isRunning {
            stop()
            start()
        }
    }

    /// Paired devices are few; anything beyond this is noise or abuse.
    static let maxClients = 8

    private func accept(_ connection: NWConnection) {
        guard let workspace, clients.count < Self.maxClients else { return connection.cancel() }
        let client = RemoteClient(connection: connection, workspace: workspace, hello: HostHello(hostName: hostName, hostId: hostId))
        clients[client.id] = client
        client.onClose = { [weak self] id in
            self?.clients[id] = nil
            self?.refreshNames()
        }
        client.onHello = { [weak self] in self?.refreshNames() }
        client.start()
    }

    private func refreshNames() {
        clientNames = clients.values.compactMap(\.deviceName).sorted()
    }

    private func broadcastTiles() {
        for c in clients.values { c.sendTiles() }
    }

    private func flush() {
        guard let workspace else { return }
        let usage = workspace.usage.orderedReadings
        let usageChanged = usage != lastUsage
        if usageChanged { lastUsage = usage }
        for c in clients.values {
            c.flush()
            if usageChanged { c.send(.usage(usage)) }
        }
    }

    /// The Mac's LAN IPv4 address, for the QR code (Bonjour covers discovery on the same network).
    static func lanAddress() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result = String(cString: host)
            if name == "en0" { break }
        }
        return result
    }
}

/// One connected device and what it is looking at.
@MainActor
final class RemoteClient {
    let id = UUID()
    private(set) var deviceName: String?
    var onClose: ((UUID) -> Void)?
    var onHello: (() -> Void)?

    private let connection: NWConnection
    private weak var workspace: Workspace?
    private let hello: HostHello
    private var authenticated = false
    private var watched: Set<String> = []
    private var pendingOutput: [String: [UInt8]] = [:]
    private var sentConversations: [String: ConversationSnapshot] = [:]
    private var closed = false
    /// Bytes handed to the connection but not yet sent. A stalled peer (a locked phone keeps TCP
    /// alive) must not make the Mac buffer terminal output without bound.
    private var inFlight = 0
    /// Terminals whose stream was dropped under backpressure; they get a fresh snapshot once drained.
    private var needsResync: Set<String> = []

    static let maxInputBytes = 64 * 1024
    static let highWater = 4 * 1024 * 1024
    static let lowWater = 512 * 1024
    static let helloDeadline: TimeInterval = 10

    init(connection: NWConnection, workspace: Workspace, hello: HostHello) {
        self.connection = connection
        self.workspace = workspace
        self.hello = hello
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch state {
                    case .failed, .cancelled: self?.close()
                    default: break
                    }
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.authenticated else { return }
                self.close()
            }
        }
        SecureChannel.receiveFrames(on: connection, handler: { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }, onEnd: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        unwatchAll()
        connection.cancel()
        onClose?(id)
    }

    func send(_ message: HostMessage, then: (() -> Void)? = nil) {
        guard authenticated, !closed, let data = try? WireProtocol.encode(message) else { return }
        inFlight += data.count
        SecureChannel.sendFrame(data, on: connection) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.inFlight -= data.count
                    then?()
                }
            }
        }
    }

    func sendTiles() {
        guard let workspace else { return }
        send(.tiles(workspace.allTiles))
        pushConversations()
    }

    func flush() {
        guard let workspace else { return }
        if inFlight > Self.highWater {
            // Too far behind: stop streaming and catch up with snapshots later.
            needsResync.formUnion(pendingOutput.keys)
            pendingOutput.removeAll(keepingCapacity: true)
            return
        }
        if inFlight < Self.lowWater, !needsResync.isEmpty {
            for id in needsResync where watched.contains(id) { sendSnapshot(id) }
            needsResync.removeAll()
        }
        guard !pendingOutput.isEmpty else { return pushConversations() }
        for (id, bytes) in pendingOutput {
            guard let t = workspace.terminals[id] else { continue }
            send(.terminalData(TerminalFrame(id: id, cols: t.terminal.cols, rows: t.terminal.rows, bytes: Data(bytes))))
        }
        pendingOutput.removeAll(keepingCapacity: true)
        pushConversations()
    }

    private func receive(_ data: Data) {
        guard let workspace else { return }
        guard let message = try? WireProtocol.decode(ClientMessage.self, from: data) else {
            if !authenticated { close() }
            return
        }
        // TLS-PSK already proved the peer knows the code; the hello just names the device.
        if case .hello(let h) = message {
            guard h.protocolVersion == WireProtocol.version else {
                authenticated = true
                send(.notice("Tessera on this Mac speaks protocol \(WireProtocol.version); please update the app.")) { [weak self] in
                    self?.close()
                }
                return
            }
            deviceName = String(h.deviceName.prefix(64))
            authenticated = true
            send(.hello(hello))
            send(.launchers(workspace.presets))
            sendTiles()
            send(.usage(workspace.usage.orderedReadings))
            onHello?()
            return
        }
        guard authenticated else { return close() }

        switch message {
        case .hello:
            break
        case .watch(let ids):
            watch(Set(ids.prefix(64)))
        case .input(let input):
            guard input.bytes.count <= Self.maxInputBytes else { return }
            workspace.terminals[input.id]?.send([UInt8](input.bytes))
        case .action(let action):
            switch action.kind {
            case .acknowledge: workspace.acknowledge(action.id)
            case .openOnHost:
                NSApp.activate()
                workspace.expand(action.id)
                if workspace.agents.sessions[action.id] != nil { workspace.openNative(action.id, at: nil) }
            case .restart: workspace.restart(action.id)
            case .close: workspace.close(action.id)
            }
        case .launch(let request):
            if let url = request.url {
                workspace.openBrowser(url)
            } else {
                workspace.launch(command: request.command, cwd: request.cwd)
            }
        case .refreshUsage:
            workspace.usage.refreshAll()
        }
    }

    private func watch(_ ids: Set<String>) {
        guard let workspace else { return }
        for id in watched.subtracting(ids) {
            workspace.terminals[id]?.outputObservers[self.id] = nil
            sentConversations[id] = nil
        }
        for id in ids.subtracting(watched) {
            guard let t = workspace.terminals[id] else { continue }
            sendSnapshot(id)
            t.outputObservers[self.id] = { [weak self] bytes in
                self?.pendingOutput[id, default: []].append(contentsOf: bytes)
            }
        }
        watched = ids
        pushConversations()
    }

    private func sendSnapshot(_ id: String) {
        guard let t = workspace?.terminals[id] else { return }
        send(.terminalSnapshot(TerminalFrame(id: id, cols: t.terminal.cols, rows: t.terminal.rows,
                                             bytes: Data(TerminalSnapshotEncoder.encode(t.terminal)))))
    }

    private func unwatchAll() {
        guard let workspace else { return }
        for id in watched { workspace.terminals[id]?.outputObservers[self.id] = nil }
        watched.removeAll()
    }

    private func pushConversations() {
        guard let workspace else { return }
        for id in watched {
            guard let session = workspace.agents.sessions[id] else { continue }
            if sentConversations[id] != session.snapshot {
                sentConversations[id] = session.snapshot
                send(.conversation(ConversationFrame(id: id, snapshot: session.snapshot)))
            }
        }
    }
}
