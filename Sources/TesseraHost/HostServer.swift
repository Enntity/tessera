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
    /// The app's own open and close, so the phone's "Open on Mac" and Close act like a click there.
    @ObservationIgnored private let open: (String) -> Void
    @ObservationIgnored private let closeTile: (String) -> Void
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [UUID: RemoteClient] = [:]
    /// Streams to connected devices; runs only while there are any.
    @ObservationIgnored private var pump: Timer?
    @ObservationIgnored private var flushes = 0
    @ObservationIgnored private var lastTiles: [TileInfo] = []
    @ObservationIgnored private var lastUsage: [UsageReading] = []
    /// Why the listener last failed; stays on show until the next start.
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private let hostId: String

    public init(workspace: Workspace, open: @escaping (String) -> Void, close: @escaping (String) -> Void) {
        self.workspace = workspace
        self.open = open
        closeTile = close
        do {
            if let saved = try Keychain.read(account: "pairing-code") {
                pairingCode = saved
            } else {
                let fresh = SecureChannel.makePairingCode()
                Keychain.set(fresh, account: "pairing-code")
                pairingCode = fresh
            }
        } catch {
            // Saved but not readable right now (access denied): use a code for this session only,
            // never replacing the one the phone is paired with.
            pairingCode = SecureChannel.makePairingCode()
        }
        if let id = Preferences.store.string(forKey: "tessera.hostId") {
            hostId = id
        } else {
            hostId = UUID().uuidString
            Preferences.store.set(hostId, forKey: "tessera.hostId")
        }
    }

    public var pairingURL: URL? {
        let address = Self.lanAddress() ?? ProcessInfo.processInfo.hostName
        return SecureChannel.pairingURL(host: address, port: port, code: pairingCode, name: hostName)
    }

    public func start() {
        guard listener == nil else { return }
        failure = nil
        do {
            let l = try NWListener(using: SecureChannel.parameters(pairingCode: pairingCode), on: NWEndpoint.Port(rawValue: port)!)
            l.service = NWListener.Service(name: hostName, type: WireProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch state {
                        case .ready: self.status = "Listening on :\(self.port)"; self.isRunning = true
                        case .failed(let e): self.failure = "Failed: \(e.localizedDescription)"; self.stop()
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
        status = failure ?? "Off"
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
    /// Connections still proving they know the code. Only paired devices count against `maxClients`,
    /// so peers without the code can't lock the phone out; when these fill up, the oldest goes.
    static let maxPending = 8

    private func accept(_ connection: NWConnection) {
        guard let workspace else { return connection.cancel() }
        let pending = clients.values.filter { !$0.authenticated }
        guard clients.count - pending.count < Self.maxClients else { return connection.cancel() }
        if pending.count >= Self.maxPending { pending.min { $0.openedAt < $1.openedAt }?.close() }
        let client = RemoteClient(connection: connection, workspace: workspace, hello: HostHello(hostName: hostName, hostId: hostId),
                                  open: open, closeTile: closeTile)
        clients[client.id] = client
        client.onClose = { [weak self] id in
            guard let self else { return }
            clients[id] = nil
            refreshNames()
            if clients.isEmpty {
                pump?.invalidate()
                pump = nil
            }
        }
        client.onHello = { [weak self] in self?.refreshNames() }
        client.start()
        if pump == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            pump = timer
        }
    }

    private func refreshNames() {
        clientNames = clients.values.compactMap(\.deviceName).sorted()
    }

    /// Terminal output goes out 20 times a second; board and usage changes twice a second.
    private func flush() {
        guard let workspace else { return }
        flushes &+= 1
        for c in clients.values { c.flush() }
        guard flushes % 10 == 0 else { return }
        let tiles = workspace.allTiles
        if tiles != lastTiles {
            lastTiles = tiles
            for c in clients.values { c.sendTiles() }
        }
        let usage = workspace.usage.orderedReadings
        if usage != lastUsage {
            lastUsage = usage
            for c in clients.values { c.send(.usage(usage)) }
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
            // An interface may have no address at all.
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
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
    let openedAt = Date()
    private(set) var deviceName: String?
    var onClose: ((UUID) -> Void)?
    var onHello: (() -> Void)?

    private let connection: NWConnection
    private weak var workspace: Workspace?
    private let hello: HostHello
    private let open: (String) -> Void
    private let closeTile: (String) -> Void
    private(set) var authenticated = false
    private var watched: Set<String> = []
    private var pendingOutput: [String: [UInt8]] = [:]
    private var sentConversations: [String: ConversationSnapshot] = [:]
    private var closed = false
    /// Bytes handed to the connection but not yet sent. A stalled peer (a locked phone keeps TCP
    /// alive) must not make the Mac queue anything without bound.
    private var inFlight = 0
    /// Messages were dropped under backpressure; once drained, the peer gets tiles, conversations
    /// and usage again.
    private var behind = false
    /// Terminals whose stream was dropped under backpressure; they get a fresh snapshot once drained.
    private var needsResync: Set<String> = []

    static let maxInputBytes = 64 * 1024
    static let highWater = 4 * 1024 * 1024
    static let lowWater = 512 * 1024
    static let helloDeadline: TimeInterval = 10

    init(connection: NWConnection, workspace: Workspace, hello: HostHello,
         open: @escaping (String) -> Void, closeTile: @escaping (String) -> Void) {
        self.connection = connection
        self.workspace = workspace
        self.hello = hello
        self.open = open
        self.closeTile = closeTile
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

    /// Queues `message`; false if it was dropped because the peer has fallen too far behind.
    @discardableResult
    func send(_ message: HostMessage, then: (() -> Void)? = nil) -> Bool {
        guard authenticated, !closed else { return false }
        guard !behind, inFlight <= Self.highWater else { behind = true; return false }
        guard let data = try? WireProtocol.encode(message) else { return false }
        inFlight += data.count
        SecureChannel.sendFrame(data, on: connection) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.inFlight -= data.count
                    then?()
                }
            }
        }
        return true
    }

    func sendTiles() {
        guard let workspace else { return }
        send(.tiles(workspace.allTiles))
        pushConversations()
    }

    func flush() {
        guard let workspace else { return }
        if behind {
            // Too far behind: stop streaming, and once drained, catch up with the current state and
            // snapshots. Snapshots dropped again stay pending, so each catch-up gets further.
            needsResync.formUnion(pendingOutput.keys)
            pendingOutput.removeAll(keepingCapacity: true)
            guard inFlight < Self.lowWater else { return }
            behind = false
            sentConversations.removeAll()
            send(.usage(workspace.usage.orderedReadings))
            sendTiles()
            let stale = needsResync
            needsResync.removeAll()
            for id in stale where watched.contains(id) { sendSnapshot(id) }
        }
        guard !pendingOutput.isEmpty else { return pushConversations() }
        for (id, bytes) in pendingOutput {
            guard let t = workspace.terminals[id] else { continue }
            if !send(.terminalData(TerminalFrame(id: id, cols: t.terminal.cols, rows: t.terminal.rows, bytes: Data(bytes)))) {
                needsResync.insert(id)
            }
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
            send(.launchers(workspace.presets + workspace.installedApps.map {
                LaunchPreset(name: $0.name, command: nil, flavor: $0.flavor)
            }))
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
                open(action.id)
            case .restart: workspace.restart(action.id)
            case .close: closeTile(action.id)
            }
        case .launch(let request):
            if let app = request.app {
                workspace.newAppConversation(app, folder: request.cwd ?? workspace.defaultDirectory, prompt: request.prompt)
            } else if let url = request.url {
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
        let frame = TerminalFrame(id: id, cols: t.terminal.cols, rows: t.terminal.rows, bytes: Data(TerminalSnapshotEncoder.encode(t.terminal)))
        if !send(.terminalSnapshot(frame)) { needsResync.insert(id) }
    }

    private func unwatchAll() {
        guard let workspace else { return }
        for id in watched { workspace.terminals[id]?.outputObservers[self.id] = nil }
        watched.removeAll()
    }

    private func pushConversations() {
        guard let workspace else { return }
        for id in watched {
            guard let session = workspace.agents.session(id) else { continue }
            if sentConversations[id] != session.snapshot {
                sentConversations[id] = session.snapshot
                send(.conversation(ConversationFrame(id: id, snapshot: session.snapshot)))
            }
        }
    }
}
