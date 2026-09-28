import SwiftUI
import TesseraKit
import UIKit

@main
struct TesseraIOSApp: App {
    @State private var store = HostStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(store.session)
                .preferredColorScheme(.dark)
                .tint(Style.cyan)
                .onOpenURL { store.handlePairingURL($0) }
                .onChange(of: phase) { _, p in if p == .active { store.session.resume() } }
        }
    }
}

/// The paired Mac. The pairing code lives in the Keychain; the rest in defaults.
@Observable
@MainActor
final class HostStore {
    let session = RemoteSession(deviceName: UIDevice.current.name)
    private(set) var host: PairedHost?
    var pairingError: String?
    /// A pairing link waiting for the user's confirmation. Links can come from anywhere (a web
    /// page, a message), so they never re-pair silently.
    var pendingPairing: PendingPairing?

    struct PendingPairing: Identifiable {
        let host: PairedHost
        let code: String
        var id: String { host.id }
    }

    private static let hostKey = "tessera.pairedHost"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hostKey),
           let saved = try? JSONDecoder().decode(PairedHost.self, from: data),
           let code = Keychain.get(account: "pair." + saved.id) {
            host = saved
            session.connect(to: saved, code: code)
        }
    }

    func pair(_ host: PairedHost, code: String) {
        if let old = self.host, old.id != host.id { Keychain.set(nil, account: "pair." + old.id) }
        Keychain.set(code, account: "pair." + host.id)
        UserDefaults.standard.set(try? JSONEncoder().encode(host), forKey: Self.hostKey)
        self.host = host
        session.connect(to: host, code: code)
    }

    func forget() {
        if let host { Keychain.set(nil, account: "pair." + host.id) }
        UserDefaults.standard.removeObject(forKey: Self.hostKey)
        session.disconnect()
        host = nil
    }

    func handlePairingURL(_ url: URL) {
        guard let (host, code) = PairedHost.fromPairingURL(url) else {
            pairingError = "That link isn't a Tessera pairing code."
            return
        }
        pendingPairing = PendingPairing(host: host, code: code)
    }
}

struct RootView: View {
    @Environment(HostStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ZStack {
            Style.void.ignoresSafeArea()
            if store.host == nil {
                PairingView()
            } else {
                BoardScreen()
            }
        }
        .alert(item: $store.pendingPairing) { pending in
            let target = pending.host.address.map { "\(pending.host.name) (\($0))" } ?? pending.host.name
            let replacing = store.host.map { "\n\nThis replaces your pairing with \($0.name)." } ?? ""
            return Alert(
                title: Text("Pair with \(pending.host.name)?"),
                message: Text("Only continue if you just scanned this code on your own Mac. \(target) will be able to show you terminals, and everything you type is sent to it.\(replacing)"),
                primaryButton: .default(Text("Pair")) { store.pair(pending.host, code: pending.code) },
                secondaryButton: .cancel())
        }
    }
}
