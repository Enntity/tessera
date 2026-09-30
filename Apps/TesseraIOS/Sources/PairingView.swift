import Network
import SwiftUI
import TesseraKit

/// First run: find the Mac on the network (or by address) and enter its pairing code. Scanning
/// the Mac's QR code with the Camera app skips all of this via the `tessera://pair` link.
struct PairingView: View {
    @Environment(HostStore.self) private var store
    @State private var discovered: [String] = []
    @State private var browser: NWBrowser?
    @State private var chosen: String?
    @State private var manualAddress = ""
    @State private var code = ""
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Style.Space.xxl) {
                HStack(spacing: Style.Space.gutter) {
                    TesseraGlyph().frame(width: 26, height: 26)
                    Text("TESSERA").font(Style.ui(17, .heavy)).tracking(4)
                }
                .padding(.top, 40)
                Text("Your whole board, in your pocket.")
                    .font(Style.ui(26, .bold)).foregroundStyle(Style.ink)
                Text("On your Mac open Tessera → Settings → iPhone, turn the link on, and scan the QR code with your Camera. Or pick your Mac below.")
                    .font(Style.ui(15)).foregroundStyle(Style.dim)

                if let error = store.pairingError {
                    Text(error).font(Style.ui(13)).foregroundStyle(Style.coral)
                }

                VStack(alignment: .leading, spacing: Style.Space.gutter) {
                    SectionLabel(text: "Macs nearby", color: Style.muted)
                    if discovered.isEmpty {
                        HStack(spacing: Style.Space.gutter) {
                            ProgressView()
                            Text("Looking for Tessera on your network…").font(Style.ui(14)).foregroundStyle(Style.dim)
                        }
                        .padding(Style.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Style.glass, in: Style.shape(Style.Radius.m))
                    }
                    ForEach(discovered, id: \.self) { name in
                        Button {
                            chosen = name
                            code = ""
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(Style.dim)
                                Text(name).font(Style.ui(16, .semibold)).foregroundStyle(Style.ink)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Style.faint)
                            }
                            .padding(Style.Space.l)
                            .background(Style.glass, in: Style.shape(Style.Radius.m))
                        }
                    }
                }

                Button(showManual ? "Hide" : "Connect by address (Tailscale, VPN)…") { withAnimation { showManual.toggle() } }
                    .font(Style.ui(14, .semibold))
                if showManual {
                    VStack(spacing: Style.Space.gutter) {
                        TextField("mac.tailnet.ts.net or 100.x.y.z", text: $manualAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Pairing code", text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Connect") {
                            store.pair(PairedHost(name: manualAddress, address: manualAddress), code: code)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualAddress.isEmpty || code.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .padding(Style.Space.xxl)
        }
        .onAppear(perform: startBrowsing)
        .onDisappear { browser?.cancel() }
        .sheet(item: Binding(get: { chosen.map(Chosen.init) }, set: { chosen = $0?.name })) { item in
            VStack(spacing: Style.Space.xl) {
                Text("Pair with \(item.name)").font(Style.ui(20, .bold))
                Text("Enter the code shown in Tessera → Settings → iPhone.").font(Style.ui(14)).foregroundStyle(Style.dim)
                SecureField("XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
                    .font(Style.mono(18))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Pair") {
                    store.pair(PairedHost(name: item.name, address: nil), code: code)
                    chosen = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(SecureChannel.normalize(code).count < 20)
            }
            .padding(Style.Space.xxl)
            .presentationDetents([.medium])
        }
    }

    struct Chosen: Identifiable {
        let name: String
        var id: String { name }
    }

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: WireProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }
            DispatchQueue.main.async { discovered = Array(Set(names)).sorted() }
        }
        b.start(queue: .main)
        browser = b
    }
}
