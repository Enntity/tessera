import SwiftUI

/// The chrome around every tile: identity, state, and an attention signal you can catch in
/// peripheral vision across a large screen.
public struct TileCard<Content: View>: View {
    @Environment(\.tesseraPrivacy) private var privacy
    let info: TileInfo
    let isSelected: Bool
    let compact: Bool
    let content: Content

    public init(info: TileInfo, isSelected: Bool = false, compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.info = info
        self.isSelected = isSelected
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        let stateColor = Style.state(info.activity)
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if !compact { footer }
        }
        .background(Style.terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Style.ink.opacity(0.55) : Style.hairline, lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay { AttentionHalo(activity: info.activity, active: info.attention, color: stateColor) }
        .overlay(alignment: .top) {
            if info.activity == .working {
                WorkingSweep(color: Style.accent(info.flavor)).padding(.top, compact ? 21 : 25)
            }
        }
        .shadow(color: info.attention ? stateColor.opacity(0.35) : .black.opacity(0.4), radius: info.attention ? 14 : 6, y: 3)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: info.flavor.symbol)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(Style.accent(info.flavor))
            Text(info.title)
                .font(Style.ui(compact ? 10.5 : 11.5, .semibold))
                .foregroundStyle(Style.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let p = info.progress {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 36).tint(Style.cyan)
            }
            StatePill(activity: info.activity, compact: compact)
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 22 : 26)
        .background(Style.glass.opacity(0.92))
        .overlay(alignment: .bottom) { Rectangle().fill(Style.hairline).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(info.detail.map { privacy ? AttributedString($0.obscured(true)) : $0.markdownPreview(160) } ?? AttributedString(info.subtitle))
                .font(Style.mono(9.5))
                .foregroundStyle(info.detail != nil && info.activity.isAttention ? Style.state(info.activity) : Style.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                Text(info.lastActivityAt.shortAge(now: ctx.date))
                    .font(Style.mono(9))
                    .foregroundStyle(Style.faint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Style.glass.opacity(0.92))
    }
}

public struct StatePill: View {
    let activity: TileActivity
    var compact = false

    public init(activity: TileActivity, compact: Bool = false) {
        self.activity = activity
        self.compact = compact
    }

    public var body: some View {
        let color = Style.state(activity)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
                .shadow(color: color, radius: activity == .working ? 3 : 0)
            if !compact || activity.isAttention {
                Text(activity.label.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// A slow breathing ring for unseen results; a rotating comet for "needs you".
struct AttentionHalo: View {
    let activity: TileActivity
    let active: Bool
    let color: Color
    @State private var phase = false

    var body: some View {
        ZStack {
            if active {
                if activity == .needsInput {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            AngularGradient(colors: [color.opacity(0.05), color, color.opacity(0.05), color.opacity(0.05)],
                                            center: .center, angle: .degrees(phase ? 360 : 0)),
                            lineWidth: 2.5)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color.opacity(phase ? 0.95 : 0.35), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate() }
        .onChange(of: active) { _, _ in animate() }
    }

    private func animate() {
        phase = false
        guard active else { return }
        withAnimation(.linear(duration: activity == .needsInput ? 2.2 : 1.6).repeatForever(autoreverses: activity != .needsInput)) {
            phase = true
        }
    }
}

/// A thin scanning line under the header while a tile is producing output.
struct WorkingSweep: View {
    let color: Color
    @State private var x: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, color.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.3, height: 1.5)
                .offset(x: geo.size.width * x)
        }
        .frame(height: 1.5)
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { x = 1.0 }
        }
    }
}
