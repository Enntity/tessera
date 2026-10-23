import Foundation
import Network
import Observation
import TesseraAPI
import TesseraKit

/// Tessera's API for agents on this Mac: MCP's JSON-RPC (`initialize`, `tools/list`, `tools/call`)
/// over plain HTTP on 127.0.0.1, behind a random token kept in a file only this user can read
/// (`AgentEndpoint`). The `tessera` command reads that file, so agents call it as a CLI or as a
/// stdio MCP server (`tessera mcp`) without handling the token. Requests from web pages are refused:
/// they carry an Origin and can't read the token.
@Observable
@MainActor
public final class AgentServer {
    public private(set) var isRunning = false
    public private(set) var status = "Off"
    public private(set) var port: UInt16?
    /// Calls served since launch, for Settings.
    public private(set) var calls = 0

    public var enabled = Preferences.store.object(forKey: "tessera.agentAPI") as? Bool ?? true {
        didSet {
            Preferences.store.set(enabled, forKey: "tessera.agentAPI")
            enabled ? start() : stop()
        }
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private let tools: AgentTools

    nonisolated static let maxBody = 1 << 20

    public init(directory: URL, tools: AgentTools) {
        self.directory = directory
        self.tools = tools
    }

    public func start() {
        guard enabled, listener == nil else { return }
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.listener === l else { return }
                        switch state {
                        case .ready:
                            guard let port = l.port?.rawValue else { return }
                            self.port = port
                            do {
                                try AgentEndpoint(port: port, token: self.token, pid: ProcessInfo.processInfo.processIdentifier)
                                    .write(to: self.directory)
                                self.status = "Listening on 127.0.0.1:\(port)"
                                self.isRunning = true
                            } catch {
                                self.status = "Couldn't write \(AgentEndpoint.fileName): \(error.localizedDescription)"
                                self.stop()
                            }
                        case .failed(let e):
                            self.status = "Failed: \(e.localizedDescription)"
                            self.stop()
                        default: break
                        }
                    }
                }
            }
            l.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
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
        AgentEndpoint.remove(from: directory, ifPid: ProcessInfo.processInfo.processIdentifier)
        isRunning = false
        port = nil
        if !status.hasPrefix("Failed") { status = "Off" }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Bound incomplete requests and long polls, including unauthenticated local clients.
        DispatchQueue.main.asyncAfter(deadline: .now() + 70) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, complete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return connection.cancel() }
                    var buffer = buffer
                    if let chunk { buffer.append(chunk) }
                    if let request = HTTPRequest(buffer) {
                        Task { @MainActor in await self.respond(connection, to: request) }
                    } else if error != nil || complete || buffer.count > Self.maxBody + 16 * 1024 {
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer: buffer)
                    }
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, to request: HTTPRequest) async {
        let reply: (status: Int, body: Data)
        if request.headers["origin"] != nil {
            reply = (403, Data(#"{"error":"browser requests are not accepted"}"#.utf8))
        } else if request.method != "POST" || request.path != "/rpc" {
            reply = (404, Data(#"{"error":"POST /rpc"}"#.utf8))
        } else if !Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer \(token)") {
            reply = (401, Data(#"{"error":"missing or wrong token; the tessera command reads it for you"}"#.utf8))
        } else {
            calls += 1
            reply = await tools.handle(request.body)
        }
        let head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : reply.status == 202 ? "Accepted" : "Error")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One HTTP/1.1 request, once all of it has arrived (headers, then Content-Length bytes of body).
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        method = String(start[0])
        path = String(start[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"),
              length >= 0, length <= AgentServer.maxBody else { return nil }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}
