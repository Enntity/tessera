import Foundation
import TesseraAPI

// `tessera`: how agents on this Mac reach the running Tessera. Each command is one call to its
// agent API (see AgentTools); `tessera mcp` serves the same tools to MCP clients over stdio.

let usage = """
    tessera — talk to the Tessera board running on this Mac

      tessera board [--waiting]                 Every tile (id, title, state, summary) and the brief
      tessera whoami                            Which tile you are
      tessera read <tile> [--lines N]           What a tile shows now
      tessera send <tile> <text…> [--type]      Message another agent (--type: into its terminal)
      tessera inbox [--wait S] [--all]          Messages for you
      tessera ask <question…> [--option A]… [--wait S]   Ask the developer; prints the answer or an id
      tessera answer <id> [--wait S]            Wait for an ask's answer
      tessera notify <text…>                    Leave the developer a note
      tessera mcp                               Serve these as MCP tools over stdio
      tessera install [--dry-run]               Put `tessera` on PATH, install the skill, register MCP

    Options: --as NAME names you when Tessera can't tell which tile you are (or set TESSERA_AS).
    Exit codes: 0 done, 1 error, 2 asked but not answered yet, 3 Tessera isn't running.
    """

struct Failure: Error, CustomStringConvertible {
    let description: String
    let code: Int32
    init(_ description: String, code: Int32 = 1) {
        self.description = description
        self.code = code
    }
}

let valueFlags: Set<String> = ["--lines", "--wait", "--option", "--as"]
var words: [String] = []
var flags: [String: [String]] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    if valueFlags.contains(arg), !args.isEmpty {
        flags[arg, default: []].append(args.removeFirst())
    } else if arg.hasPrefix("--") {
        flags[arg, default: []].append("")
    } else {
        words.append(arg)
    }
}
func flag(_ name: String) -> String? { flags[name]?.last }
func has(_ name: String) -> Bool { flags[name] != nil }

let caller = AgentCaller.current(name: flag("--as"))

/// One JSON-RPC exchange with the app. Throws code 3 when Tessera isn't running.
func rpc(_ body: [String: Any], timeout: TimeInterval = 75) throws -> (status: Int, data: Data) {
    guard let endpoint = AgentEndpoint.read() else {
        throw Failure("Tessera isn't running, or its agent API is off (Settings → Agents).", code: 3)
    }
    var request = URLRequest(url: endpoint.url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let done = DispatchSemaphore(value: 0)
    var result: Result<(Int, Data), Error> = .failure(Failure("no answer"))
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(Failure("Tessera didn't answer (\(error.localizedDescription)); is it running?", code: 3))
        } else {
            result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
        }
        done.signal()
    }.resume()
    done.wait()
    return try result.get()
}

/// The caller rides along in `_meta`, so the app can tell which tile is asking.
func withCaller(_ params: [String: Any]) -> [String: Any] {
    var params = params
    var meta = params["_meta"] as? [String: Any] ?? [:]
    meta["tessera/caller"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(caller))) ?? [:]
    params["_meta"] = meta
    return params
}

func callTool(_ name: String, _ arguments: [String: Any]) throws -> String {
    let (status, data) = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": withCaller(["name": name, "arguments": arguments])])
    guard status == 200, let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Failure("Tessera answered HTTP \(status): \(String(decoding: data, as: UTF8.self))")
    }
    if let error = reply["error"] as? [String: Any] { throw Failure(error["message"] as? String ?? "error") }
    let result = reply["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    if result["isError"] as? Bool == true { throw Failure(text) }
    return text
}

// MARK: MCP over stdio

/// Forwards each JSON-RPC line from the MCP client to the app (adding who is calling) and writes
/// the reply back. Calls run concurrently, since asking the developer can wait; writes don't interleave.
func serveMCP() -> Never {
    let out = FileHandle.standardOutput
    let lock = NSLock()
    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock()
        out.write(data + Data("\n".utf8))
        lock.unlock()
    }
    let queue = DispatchQueue(label: "tessera.mcp", attributes: .concurrent)
    let inFlight = DispatchGroup()
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        queue.async(group: inFlight) {
            guard var message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                return write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            if method == "tools/call" { message["params"] = withCaller(message["params"] as? [String: Any] ?? [:]) }
            do {
                let (status, data) = try rpc(message)
                guard id != nil, status != 202, !data.isEmpty else { return }
                if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { write(reply) }
            } catch {
                guard let id else { return }
                // Started before Tessera: still say hello, so the client keeps the server and the
                // tools work once Tessera is up.
                if method == "initialize" {
                    let version = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
                    write(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": version, "capabilities": ["tools": [:]],
                                                                 "serverInfo": ["name": "tessera", "version": "1"]]])
                } else {
                    write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "\(error)"]])
                }
            }
        }
    }
    // The client closed stdin: answer what is still in flight, then go.
    inFlight.wait()
    exit(0)
}

// MARK: Commands

func rest(from index: Int) -> String { words.dropFirst(index).joined(separator: " ") }

func waitArgument(default value: Int) -> Int { Int(flag("--wait") ?? "") ?? value }

do {
    switch words.first ?? "help" {
    case "mcp":
        serveMCP()
    case "board":
        print(try callTool("board", ["waiting_only": has("--waiting")]))
    case "whoami":
        print(try callTool("whoami", [:]))
    case "read":
        guard words.count >= 2 else { throw Failure("tessera read <tile> [--lines N]") }
        print(try callTool("read_tile", ["tile": words[1], "lines": Int(flag("--lines") ?? "") ?? 60]))
    case "send":
        guard words.count >= 3 else { throw Failure("tessera send <tile> <text…> [--type]") }
        print(try callTool("send_message", ["to": words[1], "text": rest(from: 2), "type": has("--type")]))
    case "inbox":
        print(try callTool("inbox", ["wait_seconds": waitArgument(default: 0), "all": has("--all")]))
    case "ask":
        guard words.count >= 2 else { throw Failure("tessera ask <question…> [--option A]… [--wait S]") }
        let reply = try callTool("ask_human", ["question": rest(from: 1), "options": flags["--option"] ?? [],
                                               "wait_seconds": waitArgument(default: 50)])
        print(reply)
        if reply.hasPrefix("Not answered yet") { exit(2) }
    case "answer":
        guard words.count >= 2 else { throw Failure("tessera answer <id> [--wait S]") }
        let reply = try callTool("get_answer", ["id": words[1], "wait_seconds": waitArgument(default: 50)])
        print(reply)
        if reply.hasPrefix("Not answered yet") { exit(2) }
    case "notify":
        guard words.count >= 2 else { throw Failure("tessera notify <text…>") }
        print(try callTool("notify_human", ["text": rest(from: 1)]))
    case "install":
        try Installer(dryRun: has("--dry-run")).run()
    case "help", "-h":
        print(usage)
    default:
        throw Failure("unknown command \(words.first!)\n\n\(usage)")
    }
} catch let failure as Failure {
    FileHandle.standardError.write(Data("tessera: \(failure.description)\n".utf8))
    exit(failure.code)
} catch {
    FileHandle.standardError.write(Data("tessera: \(error.localizedDescription)\n".utf8))
    exit(1)
}
