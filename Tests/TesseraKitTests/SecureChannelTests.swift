import Network
import XCTest
@testable import TesseraKit

final class SecureChannelTests: XCTestCase {
    /// Echo server on a random port using the given pairing code.
    private func startEcho(code: String) throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: SecureChannel.parameters(pairingCode: code), on: .any)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            SecureChannel.receiveFrames(on: conn, handler: { SecureChannel.sendFrame($0, on: conn) }, onEnd: { _ in })
        }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    private func roundTrip(serverCode: String, clientCode: String, payload: Data = Data("ping".utf8)) throws -> Data? {
        let (listener, port) = try startEcho(code: serverCode)
        defer { listener.cancel() }
        let conn = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                using: SecureChannel.parameters(pairingCode: clientCode))
        let done = expectation(description: "reply or failure")
        var reply: Data?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: SecureChannel.sendFrame(payload, on: conn)
            case .failed, .waiting: done.fulfill()
            default: break
            }
        }
        conn.start(queue: .global())
        SecureChannel.receiveFrames(on: conn, handler: { data in
            reply = data
            done.fulfill()
        }, onEnd: { _ in })
        wait(for: [done], timeout: 8)
        conn.cancel()
        return reply
    }

    func testMatchingCodeExchangesFrames() throws {
        let code = SecureChannel.makePairingCode()
        let reply = try roundTrip(serverCode: code, clientCode: code.lowercased().replacingOccurrences(of: "-", with: " "))
        XCTAssertEqual(reply.map { String(decoding: $0, as: UTF8.self) }, "ping")
    }

    func testLargeFrameSurvivesChunking() throws {
        let code = SecureChannel.makePairingCode()
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try roundTrip(serverCode: code, clientCode: code, payload: payload), payload)
    }

    func testWrongCodeIsRejected() throws {
        let reply = try roundTrip(serverCode: SecureChannel.makePairingCode(), clientCode: SecureChannel.makePairingCode())
        XCTAssertNil(reply)
    }

    func testPairingURLRoundTrip() {
        let url = SecureChannel.pairingURL(host: "10.0.0.5", port: 47474, code: "ABCDE-FGHJK", name: "Studio Mac")!
        let (host, code) = PairedHost.fromPairingURL(url)!
        XCTAssertEqual(host.address, "10.0.0.5")
        XCTAssertEqual(host.name, "Studio Mac")
        XCTAssertEqual(code, "ABCDE-FGHJK")
    }
}
