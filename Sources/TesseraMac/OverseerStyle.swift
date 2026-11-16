import SwiftUI
import TesseraHost
import TesseraKit

/// The overseer's mark: a small aurora orb with a sparkles glyph, still while it waits and
/// turning slowly while it is at work. Always still under Reduce Motion.
struct OverseerOrb: View {
    let size: CGFloat
    var active = false

    var body: some View {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack {
            if active, !reduced {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    orb(rotation: .degrees(t * 60), // once around every six seconds
                        glow: 0.35 + 0.15 * sin(t * .pi))
                }
            } else {
                orb(rotation: .zero, glow: 0.5)
            }
        }
    }

    private func orb(rotation: Angle, glow: Double) -> some View {
        Circle()
            .fill(Style.Overseer.aurora(rotation: rotation))
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Style.Overseer.violet.opacity(glow), radius: size / 2)
            .frame(width: size, height: size)
    }
}

/// The aurora drawn around a card or panel: a thin gradient ring, turning while the overseer is
/// at work, with a soft glow outside it.
private struct AuroraBorder: ViewModifier {
    var active: Bool
    var radius: CGFloat

    func body(content: Content) -> some View {
        let ring = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content
            .overlay {
                if active, !reduced {
                    TimelineView(.animation) { context in
                        ring.strokeBorder(
                            Style.Overseer.aurora(rotation: .degrees(context.date.timeIntervalSinceReferenceDate * 60)),
                            lineWidth: 1.5)
                    }
                } else {
                    ring.strokeBorder(Style.Overseer.aurora(), lineWidth: 1.5)
                }
            }
            .shadow(color: Style.Overseer.violet.opacity(active ? 0.45 : 0.28), radius: 16)
    }
}

extension View {
    func auroraBorder(active: Bool, radius: CGFloat = Style.Radius.l) -> some View {
        modifier(AuroraBorder(active: active, radius: radius))
    }
}
