import SwiftUI

/// One phase for every tile's age clock, so their updates land together.
private let ageClockStart = Date()

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
        let halo = info.isUnseen ? info.activity : nil
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if !compact { footer }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Style.ink.opacity(0.55) : Style.hairline, lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay { if let halo { AttentionHalo(activity: halo) } }
        .overlay(alignment: .top) {
            if info.activity == .working {
                Ambient(.sweep(Style.accent(info.flavor))).frame(height: 1.5).padding(.top, compact ? 21 : 25)
            }
        }
        // The glow sits on a still shape behind the card, so the effects above never re-render it.
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Style.terminalBackground)
                .shadow(color: halo.map { Style.state($0).opacity(0.35) } ?? .black.opacity(0.4), radius: halo != nil ? 14 : 6, y: 3)
        }
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
            TimelineView(.periodic(from: ageClockStart, by: 15)) { ctx in
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

    var body: some View {
        let color = Style.state(activity)
        if activity == .needsInput {
            Ambient(.comet(color, cornerRadius: 10, lineWidth: 2.5, period: 2.2))
        } else {
            Ambient(.pulse(color, cornerRadius: 10, lineWidth: 2, low: 0.35, high: 0.95, period: 1.6))
        }
    }
}
