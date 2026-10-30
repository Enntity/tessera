import SwiftUI
import TesseraHost
import TesseraKit

/// The answers an agent's question offers, and a reply of the user's own, under its lane row.
struct DeskAnswers: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var reply = ""

    var body: some View {
        let desk = model.workspace.desk
        if let options = desk.choices(for: id) {
            VStack(alignment: .leading, spacing: Style.Space.xs) {
                if !options.isEmpty {
                    HStack(spacing: Style.Space.xs) {
                        ForEach(options, id: \.self) { option in
                            Button { desk.respond(id, with: option) } label: {
                                Text(option).font(Style.ui(.caption, .semibold)).lineLimit(1)
                                    .foregroundStyle(Style.amber)
                                    .padding(.horizontal, Style.Space.s)
                                    .frame(height: Style.Metrics.key)
                                    .background(Style.amber.opacity(Style.Tint.fill), in: Style.shape(Style.Radius.xs))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if options != ["Deliver", "Don't"] {
                    TextField("Reply…", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .font(Style.caption)
                        .onSubmit {
                            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            desk.respond(id, with: text)
                            reply = ""
                        }
                }
            }
        }
    }
}

/// Settings → Agents: the steward's model, and the API agents on this Mac use.
struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var url = ""
    @State private var modelName = ""
    @State private var key = ""
    @State private var installOutput: String?
    @State private var installing = false

    var body: some View {
        let steward = model.workspace.steward
        let server = model.workspace.agentServer
        @Bindable var desk = model.workspace.desk
        Form {
            Section("Steward") {
                Toggle("Summarize tiles and brief the board", isOn: $enabled)
                TextField("Endpoint", text: $url, prompt: Text("http://lloom.example:8100/v1"))
                TextField("Model", text: $modelName, prompt: Text("tessera"))
                SecureField("API key", text: $key, prompt: Text(steward.hasKey ? "saved in Keychain" : "if the endpoint needs one"))
                HStack {
                    stewardStatus(steward)
                    Spacer()
                    Button("Save") {
                        _ = steward.configure(.init(enabled: enabled, url: url, model: modelName.isEmpty ? "tessera" : modelName), key: key)
                        key = ""
                    }
                    .disabled(enabled && StewardService.baseURL(url) == nil)
                }
                Text("Any OpenAI-compatible endpoint; a LLooM gateway with a `tessera` alias on a local model keeps everything on your machines. What tiles show is sent with credentials removed, and nothing is sent in privacy mode. The steward only suggests: nothing closes or changes unless you click.").note()
            }
            Section("Agent API") {
                Toggle("Let agents on this Mac use Tessera", isOn: Bindable(server).enabled)
                Text(server.isRunning ? "\(server.status) · \(server.calls) calls" : server.status).note()
                Toggle("Agents may type messages into terminal agents without asking", isOn: $desk.typingAllowed)
                Text("Agents see the board, read tiles, message each other and ask you questions through the `tessera` command or its MCP server. Off: each typed delivery waits for your OK in the lane.").note()
                HStack {
                    Spacer()
                    Button(installing ? "Installing…" : "Install Command, Skill & MCP…") {
                        installing = true
                        Task {
                            installOutput = await Task.detached { Self.install() }.value
                            installing = false
                        }
                    }
                        .disabled(installing)
                        .help("Installs the `tessera` command, shared skill, and MCP setup for Claude Code, Codex and Devin")
                }
                if let installOutput { Text(installOutput).font(Style.mono(.caption)).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = steward.config.enabled
            url = steward.config.url.isEmpty ? (model.workspace.fleet.config.map { $0.url.hasSuffix("/") ? $0.url + "v1" : $0.url + "/v1" } ?? "") : steward.config.url
            modelName = steward.config.model
        }
    }

    @ViewBuilder private func stewardStatus(_ steward: StewardService) -> some View {
        switch steward.status {
        case .off: Text("Off").note()
        case .idle: Text(steward.brief.map { "Briefed \($0.at.shortAge()) ago · \(steward.summaries.count) tiles summarized" } ?? "Starting…").note()
        case .thinking: Text("Thinking…").note()
        case .failed(let why): Text(why).font(Style.ui(.label)).foregroundStyle(Style.coral).lineLimit(2)
        }
    }

    /// Runs the bundled `tessera` command's installer and returns what it said.
    nonisolated static func install() -> String {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tessera-cli"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tessera-cli")].compactMap { $0 }
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return "The tessera command isn't in this build of Tessera."
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["install"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        return process.terminationStatus == 0 ? text : "Installation incomplete (exit \(process.terminationStatus)):\n\(text)"
    }
}

private extension Text {
    func note() -> some View { font(Style.ui(.label)).foregroundStyle(Style.dim) }
}
