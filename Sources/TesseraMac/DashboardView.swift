import SwiftUI
import TesseraHost
import TesseraKit

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                HUDBar()
                HStack(spacing: 0) {
                    BoardView()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    if model.showSidebar {
                        AccountsSidebar()
                            .frame(width: 290)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            if model.showPalette {
                CommandPalette()
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .coordinateSpace(name: "window")
        .background(WindowAccessor { model.window = $0 })
        .ignoresSafeArea()
        .animation(.spring(duration: 0.25), value: model.showPalette)
    }
}

/// The void behind the board: a faint lattice with a glow, so tiles float.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Style.void
            Canvas { ctx, size in
                let step: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    var y: CGFloat = 0
                    while y < size.height {
                        path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                        y += step
                    }
                    x += step
                }
                ctx.fill(path, with: .color(.white.opacity(0.05)))
            }
            RadialGradient(colors: [Style.cyan.opacity(0.07), .clear], center: .top, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Style.violet.opacity(0.05), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
    }
}

/// Captures the hosting NSWindow so we can convert between window and screen space.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.isMovableByWindowBackground = false
                w.titlebarAppearsTransparent = true
                w.backgroundColor = NSColor(Style.void)
                onWindow(w)
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HUDBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var workspace = model.workspace
        let counts = model.workspace.counts
        HStack(spacing: 14) {
            Wordmark()
                .padding(.leading, 78) // clear the traffic lights
            Divider().frame(height: 18).overlay(Style.hairline)
            HStack(spacing: 8) {
                CountChip(value: counts.needsInput, label: "need you", color: Style.amber, pulse: counts.needsInput > 0) {
                    model.jumpToAttention()
                }
                CountChip(value: counts.done, label: "done", color: Style.mint, pulse: false) {
                    model.jumpToAttention()
                }
                CountChip(value: counts.working, label: "working", color: Style.cyan, pulse: false) {
                    withAnimation(.spring(duration: 0.35)) { workspace.filter = .all }
                }
            }
            Spacer()
            Picker("", selection: $workspace.filter.animation(.spring(duration: 0.35))) {
                ForEach(Workspace.Filter.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            Spacer()
            MachineVitals()
            Button {
                model.paletteMode = .all
                model.showPalette = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New").font(Style.ui(12, .semibold))
                    Text("⌘K").font(Style.mono(10)).foregroundStyle(Style.faint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Style.cyan.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Style.cyan.opacity(0.35)))
                .foregroundStyle(Style.cyan)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.spring(duration: 0.3)) { model.showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right").foregroundStyle(model.showSidebar ? Style.ink : Style.dim)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(height: 44)
        .background(.ultraThinMaterial.opacity(0.35))
        .overlay(alignment: .bottom) { Rectangle().fill(Style.hairline).frame(height: 1) }
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            TesseraGlyph().frame(width: 16, height: 16)
            Text("TESSERA")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(Style.ink)
        }
    }
}

struct CountChip: View {
    let value: Int
    let label: String
    let color: Color
    let pulse: Bool
    let action: () -> Void
    @State private var glow = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(value)")
                    .font(Style.mono(12, .bold))
                    .contentTransition(.numericText())
                Text(label).font(Style.ui(11))
            }
            .foregroundStyle(value > 0 ? color : Style.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background((value > 0 ? color : Style.faint).opacity(glow ? 0.28 : 0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: value)
        .onChange(of: pulse, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { glow = true }
            } else {
                withAnimation(.default) { glow = false }
            }
        }
    }
}

struct MachineVitals: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.workspace.stats
        HStack(spacing: 10) {
            Sparkline(values: stats.cpuHistory, color: Style.cyan).frame(width: 46, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text("CPU \(Int(stats.cpu * 100))%").font(Style.mono(9.5, .semibold)).foregroundStyle(Style.ink)
                Text("MEM \(Int(stats.memoryUsed * 100))% of \(Int(stats.memoryTotalGB))G").font(Style.mono(9)).foregroundStyle(Style.dim)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(Style.mono(13, .semibold))
                    .foregroundStyle(Style.ink)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(v)))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.3), .clear]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}
