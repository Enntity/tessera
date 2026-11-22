import Foundation

/// The `codex app-server` stdio JSON-RPC client used for `thread/name/set`. One shot: spawn,
/// initialize, send the rename, wait for its result, terminate. The request builders are pure so
/// tests can check the wire shape without a codex binary; `renameThread` takes an executable path
/// so tests can substitute a script.
public enum CodexAppServer {
    public struct Failure: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// New-line JSON-RPC: `{"method":"initialize","id":1,"params":{…}}`.
    public static func initializeRequest(id: Int = 1, clientName: String = "Tessera",
                                         version: String = "0.1.0") -> String {
        #"{"method":"initialize","id":\#(id),"params":{"clientInfo":{"name":"\#(clientName)","title":"\#(clientName)","version":"\#(version)"}}}"#
    }

    /// `{"method":"initialized"}` — the notification that finishes the handshake.
    public static let initializedNotification = #"{"method":"initialized","params":{}}"#

    /// `{"method":"thread/name/set","id":2,"params":{"threadId":…,"name":…}}`.
    public static func renameRequest(id: Int = 2, threadId: String, name: String) -> String {
        let params = (try? JSONSerialization.data(withJSONObject:
            ["method": "thread/name/set", "id": id,
             "params": ["threadId": threadId, "name": name]])).map { String(decoding: $0, as: UTF8.self) }
        return params ?? ""
    }

    /// The codex binary on the user's PATH, searching the same fallback directories the
    /// installer does (`which` there can't be shared: it lives in the CLI module). nil when
    /// nothing executable is found.
    public static func codexBinary() -> URL? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            + ":\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Rename a Codex thread through `codex app-server`. Throws `Failure` on any step that doesn't
    /// answer within `timeout` seconds or answers with an error; the child is always terminated.
    /// `executable` lets tests substitute a script; nil resolves `codex` on PATH.
    public static func renameThread(_ threadId: String, to name: String, executable: URL? = nil,
                                    timeout: TimeInterval = 15) async throws {
        guard let url = executable ?? codexBinary() else {
            throw Failure("no codex binary on PATH, so Codex threads can't be renamed")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["app-server"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw Failure("codex app-server didn't start: \(error.localizedDescription)") }
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData) }
        stdin.fileHandleForWriting.write(Data((initializeRequest() + "\n").utf8))
        stdin.fileHandleForWriting.write(Data((initializedNotification + "\n").utf8))
        stdin.fileHandleForWriting.write(Data((renameRequest(threadId: threadId, name: name) + "\n").utf8))
        // stdin stays open until the answer lands: some app-server builds exit on EOF.

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = lines.take() {
                guard let message = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                      (message["id"] as? Int) == 2 else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw Failure(error["message"] as? String ?? "codex app-server refused the rename")
                }
                if message["result"] != nil { return }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure("codex app-server didn't answer within \(Int(timeout)) seconds")
    }

    /// Collects stdout, hands back complete lines.
    final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var ready: [String] = []

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            while let cut = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: cut)
                pending = pending.suffix(from: cut + 1)
                if let text = String(data: line, encoding: .utf8), !text.isEmpty { ready.append(text) }
            }
        }

        func take() -> String? {
            lock.lock(); defer { lock.unlock() }
            return ready.isEmpty ? nil : ready.removeFirst()
        }
    }
}
