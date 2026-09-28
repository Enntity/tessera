import SwiftUI
import SwiftTerm
import TesseraKit

/// A host terminal on the phone. Reader mode re-wraps the text to the screen; Screen mode shows the
/// exact grid with pinch-to-zoom. Either way, answering an agent is one tap.
struct TerminalScreen: View {
    @Environment(RemoteSession.self) private var session
    let id: String
    @State private var mode: Mode = .reader
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var draft = ""
    @FocusState private var typing: Bool

    enum Mode: String, CaseIterable { case reader = "Reader", screen = "Screen" }

    var body: some View {
        let info = session.tiles.first { $0.id == id }
        let revision = session.revisions[id] ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let info { StatePill(activity: info.activity) }
                Text(info?.detail ?? info?.subtitle ?? "").font(Style.mono(11))
                    .foregroundStyle(info?.activity == .needsInput ? Style.amber : Style.dim).lineLimit(1)
                Spacer()
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).frame(width: 150)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Style.glass)

            Group {
                if let mirror = session.mirrors[id] {
                    switch mode {
                    case .reader: reader(mirror, revision: revision)
                    case .screen: screen(mirror, revision: revision)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Style.terminalBackground)
            .onTapGesture { typing = false }

            inputBar(needsInput: info?.activity == .needsInput)
        }
    }

    private func reader(_ mirror: TerminalMirror, revision: Int) -> some View {
        let lines = mirror.terminal.transcriptLines()
        return ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(Style.mono(11.5))
                .foregroundStyle(Style.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .id(revision)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func screen(_ mirror: TerminalMirror, revision: Int) -> some View {
        GeometryReader { geo in
            let t: Terminal = mirror.terminal
            let cell = geo.size.width / CGFloat(max(t.cols, 1)) * zoom * pinch
            ScrollView([.horizontal, .vertical]) {
                TerminalThumbnail(terminal: t, revision: revision)
                    .equatable()
                    .frame(width: cell * CGFloat(t.cols), height: cell * 2.05 * CGFloat(t.rows))
            }
            .defaultScrollAnchor(.bottomLeading)
            .gesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { _ in
                    zoom = min(5, max(1, zoom * pinch))
                    pinch = 1
                })
        }
    }

    private func inputBar(needsInput: Bool) -> some View {
        VStack(spacing: 8) {
            if needsInput {
                HStack(spacing: 8) {
                    ForEach(["1", "2", "3", "y", "n"], id: \.self) { answer in
                        Button(answer) { session.type(answer, into: id) }
                            .font(Style.mono(15, .bold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Style.amber.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(Style.amber)
                    }
                    Button("⏎") { session.key(.enter, into: id) }
                        .font(Style.mono(15, .bold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Style.amber.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(Style.amber)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([TerminalKey.escape, .tab, .ctrlC, .up, .down, .left, .right, .backspace, .ctrlD], id: \.self) { key in
                        Button(key.label) { session.key(key, into: id) }
                            .font(Style.mono(13, .semibold))
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .background(Style.glass, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Style.ink)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Send to terminal", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(Style.mono(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Style.glass, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
            }
        }
        .padding(10)
        .background(Style.deck)
        .animation(.spring(duration: 0.3), value: needsInput)
    }

    private func send() {
        // The Return that submitted the field must not reach the program as an extra keystroke.
        var text = draft
        while text.last?.isNewline == true { text.removeLast() }
        session.type(text.replacingOccurrences(of: "\n", with: "\r") + "\r", into: id)
        draft = ""
    }
}

struct UsageScreen: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(session.usage) { reading in
                        UsageRow(reading: reading) { openURL($0) }
                    }
                    if session.usage.isEmpty {
                        Text("Connect providers in Tessera on your Mac.").font(Style.ui(14)).foregroundStyle(Style.dim).padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .background(Style.void)
            .refreshable { session.send(.refreshUsage) }
            .navigationTitle("Accounts")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LaunchSheet: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Start on your Mac") {
                    ForEach(session.launchers) { preset in
                        Button {
                            session.send(.launch(LaunchRequest(command: preset.command)))
                            dismiss()
                        } label: {
                            Label(preset.name, systemImage: preset.flavor.symbol).foregroundStyle(Style.accent(preset.flavor))
                        }
                    }
                }
                Section("Run a command") {
                    TextField("npm test", text: $command)
                        .font(Style.mono(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit {
                            session.send(.launch(LaunchRequest(command: command)))
                            dismiss()
                        }
                }
                Section("Open a web tile") {
                    TextField("github.com", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit {
                            session.send(.launch(LaunchRequest(url: url)))
                            dismiss()
                        }
                }
            }
            .navigationTitle("New Tile")
            .toolbar { Button("Cancel") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
