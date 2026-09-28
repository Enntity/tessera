import CoreImage.CIFilterBuiltins
import SwiftUI
import TesseraHost
import TesseraKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettings().tabItem { Label("Accounts", systemImage: "creditcard") }
            RemoteSettings().tabItem { Label("iPhone", systemImage: "iphone") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
    }
}

struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var kind: UsageProviderKind = .openrouter
    @State private var name = ""
    @State private var key = ""
    @State private var budget = ""
    @State private var customURL = ""
    @State private var customHeader = ""
    @State private var customPath = ""
    @State private var customTopUp = ""

    var body: some View {
        let usage = model.workspace.usage
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(usage.configs) { config in
                    HStack {
                        Image(systemName: config.kind.spec.symbol).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(config.name)
                            Text(config.kind.spec.keyHint == nil ? "No key needed" : (usage.hasKey(config.id) ? "Key saved in Keychain" : "No key"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let budget = config.monthlyBudget { Text("Budget $\(Int(budget))").font(.caption).foregroundStyle(.secondary) }
                        Button(role: .destructive) { usage.remove(id: config.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { usage.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("Keys are stored in your login Keychain and only sent to the provider they belong to. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Account…") { model.showAddAccount = true }
            }
        }
        .padding(18)
        .sheet(isPresented: Bindable(model).showAddAccount) { addSheet }
    }

    /// A focused sheet: pick a provider, paste a key, Connect — or Cancel / Esc.
    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an Account").font(.title3.weight(.semibold))
            Form {
                Picker("Provider", selection: $kind) {
                    ForEach(UsageProviderKind.allCases, id: \.self) { k in Text(k.spec.name).tag(k) }
                }
                Text(kind.spec.help).font(.caption).foregroundStyle(.secondary)
                TextField("Display name", text: $name, prompt: Text(kind.spec.name))
                if let hint = kind.spec.keyHint {
                    SecureField("Key", text: $key, prompt: Text(hint))
                }
                if kind == .openai || kind == .anthropic || kind == .custom {
                    TextField("Monthly budget (USD)", text: $budget, prompt: Text("optional"))
                }
                if kind == .custom {
                    TextField("Balance URL", text: $customURL, prompt: Text("https://api.example.com/v1/balance"))
                    TextField("Auth header", text: $customHeader, prompt: Text("Authorization"))
                    TextField("JSON path to number", text: $customPath, prompt: Text("data.balance"))
                    TextField("Top-up URL", text: $customTopUp, prompt: Text("https://…/billing"))
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { closeSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kind.spec.keyHint != nil && kind != .custom && key.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func closeSheet() {
        model.showAddAccount = false
        name = ""; key = ""; budget = ""; customURL = ""; customHeader = ""; customPath = ""; customTopUp = ""
    }

    private func connect() {
        let config = UsageProviderConfig(kind: kind, name: name.isEmpty ? nil : name, monthlyBudget: Double(budget),
                                         customBalanceURL: customURL.isEmpty ? nil : customURL,
                                         customAuthHeader: customHeader.isEmpty ? nil : customHeader,
                                         customJSONPath: customPath.isEmpty ? nil : customPath,
                                         customTopUpURL: customTopUp.isEmpty ? nil : customTopUp)
        model.workspace.usage.add(config, key: key.isEmpty ? nil : key)
        closeSheet()
    }
}

struct RemoteSettings: View {
    @Environment(AppModel.self) private var model
    @State private var revealCode = false

    var body: some View {
        let server = model.server
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Allow the Tessera iPhone app to connect", isOn: Binding(get: { server.isRunning }, set: { model.setRemote($0) }))
                    .toggleStyle(.switch)
                Text(server.status).font(.caption).foregroundStyle(.secondary)
                Text("Your iPhone finds this Mac over Bonjour on the same network, or by address over Tailscale/VPN. The connection is encrypted with a key derived from the pairing code; anyone with the code can see and type into your terminals.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GroupBox("Pairing code") {
                    HStack {
                        Text(revealCode ? server.pairingCode : String(repeating: "•", count: 23))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(revealCode ? "Hide" : "Show") { revealCode.toggle() }
                        Button("New Code") { server.regenerateCode() }
                    }
                    .padding(4)
                }
                if !server.clientNames.isEmpty {
                    Text("Connected: " + server.clientNames.joined(separator: ", ")).font(.callout)
                }
                Spacer()
            }
            VStack(spacing: 8) {
                if revealCode, let url = server.pairingURL, let image = QRCode.image(for: url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    Text("Scan with the Tessera iPhone app").font(.caption).foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 220, height: 220)
                        .overlay(Text("Show the code to\ndisplay the QR").multilineTextAlignment(.center).foregroundStyle(.secondary))
                }
            }
        }
        .padding(20)
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var trusted = WindowPlacer.isTrusted

    var body: some View {
        @Bindable var workspace = model.workspace
        Form {
            Section("New tiles") {
                HStack {
                    Text("Default folder")
                    Spacer()
                    Text(workspace.defaultDirectory.abbreviatingHome).foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Section("Claude & Codex apps") {
                Toggle("Snap the app's window onto the tile when opening a session", isOn: $workspace.placeNativeWindows)
                    .onChange(of: workspace.placeNativeWindows) { _, _ in workspace.save() }
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility access granted" : "Needs Accessibility access to move other apps' windows")
                    Spacer()
                    if !trusted {
                        Button("Grant…") {
                            WindowPlacer.requestTrust()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { trusted = WindowPlacer.isTrusted }
                        }
                    }
                }
                Stepper("Show sessions active in the last \(Int(workspace.agents.lookback / 3600)) hours",
                        value: Binding(get: { workspace.agents.lookback / 3600 }, set: { workspace.agents.lookback = $0 * 3600 }),
                        in: 1...240, step: 6)
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.workspace.defaultDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            model.workspace.defaultDirectory = url.path
            model.workspace.save()
        }
    }
}
