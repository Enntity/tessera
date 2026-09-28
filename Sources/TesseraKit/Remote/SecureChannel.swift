import CryptoKit
import Foundation
import Network
import Security

/// Network parameters shared by the host listener and remote clients.
///
/// The channel is TLS with a pre-shared key derived from the pairing code, the same scheme Apple
/// uses for peer-to-peer apps: nobody without the code can connect, and everything on the wire
/// (terminal output, keystrokes) is encrypted. Messages are length-prefixed frames on top.
public enum SecureChannel {
    static let identity = "tessera-v1"

    public static func parameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: Data(normalize(pairingCode).utf8)))
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true

        let params = NWParameters(tls: tls, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: FrameProtocol.definition), at: 0)
        return params
    }

    /// Codes are shown grouped ("K7QF-2MXP-…") and typed loosely; compare on the bare characters.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 20 characters from an unambiguous alphabet ≈ 100 bits.
    public static func makePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: chars.count, by: 5).map { String(chars[$0..<min($0 + 5, chars.count)]) }.joined(separator: "-")
    }

    /// `tessera://pair?host=…&port=…&code=…&name=…` — what the Mac shows as a QR code.
    public static func pairingURL(host: String, port: UInt16, code: String, name: String) -> URL? {
        var c = URLComponents()
        c.scheme = "tessera"
        c.host = "pair"
        c.queryItems = [.init(name: "host", value: host), .init(name: "port", value: String(port)),
                        .init(name: "code", value: code), .init(name: "name", value: name)]
        return c.url
    }

    public static func sendFrame(_ data: Data, on connection: NWConnection, completion: ((NWError?) -> Void)? = nil) {
        let meta = NWProtocolFramer.Message(definition: FrameProtocol.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { completion?($0) })
    }

    /// Reads frames until the connection fails, delivering each payload.
    public static func receiveFrames(on connection: NWConnection, handler: @escaping (Data) -> Void, onEnd: @escaping (NWError?) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty { handler(data) }
            if let error {
                onEnd(error)
                return
            }
            receiveFrames(on: connection, handler: handler, onEnd: onEnd)
        }
    }
}

/// `[UInt32 big-endian length][payload]`, one JSON message per frame.
final class FrameProtocol: NWProtocolFramerImplementation {
    static let label = "TesseraFrame"
    static let definition = NWProtocolFramer.Definition(implementation: FrameProtocol.self)
    static let maxFrame = 32 * 1024 * 1024

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        var length = UInt32(messageLength).bigEndian
        framer.writeOutput(data: Data(bytes: &length, count: 4))
        do { try framer.writeOutputNoCopy(length: messageLength) } catch {}
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var length: UInt32 = 0
            let parsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                guard let buffer, buffer.count >= 4 else { return 0 }
                length = buffer.loadUnaligned(as: UInt32.self).bigEndian
                return 4
            }
            guard parsed else { return 4 }
            guard length <= Self.maxFrame else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            guard framer.deliverInputNoCopy(length: Int(length), message: message, isComplete: true) else { return 0 }
        }
    }
}
