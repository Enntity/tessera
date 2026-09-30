import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A continuous effect run by Core Animation in the render server. SwiftUI only adds or removes it,
/// so an animating tile costs the app no per-frame work. It stops while the tile is out of view
/// (`tesseraMotion`) or the window is hidden.
public struct Ambient: View {
    public enum Effect: Equatable {
        /// A soft highlight sweeping left to right.
        case sweep(Color)
        /// A rounded shape (an outline when `lineWidth` > 0, a capsule when `cornerRadius` is nil)
        /// breathing between two opacities.
        case pulse(Color, cornerRadius: CGFloat?, lineWidth: CGFloat = 0, low: Float, high: Float, period: Double)
        /// Three dots fading in turn.
        case dots(Color, size: CGFloat, spacing: CGFloat)
    }

    @Environment(\.tesseraMotion) private var motion
    let effect: Effect

    public init(_ effect: Effect) { self.effect = effect }

    public var body: some View {
        if motion { AmbientHost(effect: effect).allowsHitTesting(false) }
    }
}

/// Three dots fading in turn while an agent writes.
struct TypingDots: View {
    let color: Color
    var size: CGFloat = 4
    var spacing: CGFloat = 3

    var body: some View {
        Ambient(.dots(color, size: size, spacing: spacing))
            .frame(width: size * 3 + spacing * 2, height: size)
    }
}

#if os(macOS)
private struct AmbientHost: NSViewRepresentable {
    let effect: Ambient.Effect
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { view.effect = effect }
}
#else
private struct AmbientHost: UIViewRepresentable {
    let effect: Ambient.Effect
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { view.effect = effect }
}
#endif

final class AmbientView: PlatformView {
    var effect: Ambient.Effect? {
        didSet { if effect != oldValue { rebuild() } }
    }
    private var content: CALayer?
    private var animated: (layer: CALayer, animation: CAAnimation)?
    private static let key = "ambient"

    #if os(macOS)
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: the layer tree is ours, AppKit leaves it alone.
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(syncAnimation),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        syncAnimation()
    }

    private var isShown: Bool { window?.occlusionState.contains(.visible) == true }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncAnimation()
    }

    private var isShown: Bool { window != nil }
    #endif

    private var host: CALayer? { layer }

    private func rebuild() {
        content?.removeFromSuperlayer()
        content = nil
        animated = nil
        guard let effect, let host else { return }
        let made: CALayer
        let animation: CABasicAnimation
        switch effect {
        case .sweep(let color):
            let gradient = CAGradientLayer()
            let c = Self.cg(color)
            gradient.colors = [c.copy(alpha: 0)!, c.copy(alpha: 0.9)!, c.copy(alpha: 0)!]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [-0.3, -0.15, 0]
            // A highlight 30% of the width wide, travelling from just off the left edge to past the right.
            animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = [-0.3, -0.15, 0]
            animation.toValue = [1.0, 1.15, 1.3]
            animation.duration = 1.4
            made = gradient
            animated = (gradient, animation)
        case .pulse(let color, _, let lineWidth, let low, let high, let period):
            let shape = CALayer()
            shape.cornerCurve = .continuous
            if lineWidth > 0 {
                shape.borderColor = Self.cg(color)
                shape.borderWidth = lineWidth
            } else {
                shape.backgroundColor = Self.cg(color)
            }
            shape.opacity = high
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = low
            animation.toValue = high
            animation.duration = period
            animation.autoreverses = true
            made = shape
            animated = (shape, animation)
        case .dots(let color, let size, let spacing):
            let dot = CALayer()
            dot.backgroundColor = Self.cg(color)
            dot.cornerRadius = size / 2
            let row = CAReplicatorLayer()
            row.instanceCount = 3
            row.instanceDelay = 0.15
            row.instanceTransform = CATransform3DMakeTranslation(size + spacing, 0, 0)
            row.addSublayer(dot)
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.25
            animation.toValue = 1
            animation.duration = 0.5
            animation.autoreverses = true
            made = row
            animated = (dot, animation)
        }
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        host.addSublayer(made)
        content = made
        place()
        syncAnimation()
    }

    private func place() {
        guard let content, let effect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        switch effect {
        case .sweep:
            break
        case .pulse(_, let radius, _, _, _, _):
            content.cornerRadius = min(radius ?? .infinity, min(bounds.width, bounds.height) / 2)
        case .dots(_, let size, _):
            content.sublayers?.first?.frame = CGRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
        }
        CATransaction.commit()
    }

    /// Animations run only while someone can see them.
    @objc private func syncAnimation() {
        guard let (layer, animation) = animated else { return }
        if isShown {
            if layer.animation(forKey: Self.key) == nil { layer.add(animation, forKey: Self.key) }
        } else {
            layer.removeAnimation(forKey: Self.key)
        }
    }

    #if os(macOS)
    private static func cg(_ color: Color) -> CGColor { NSColor(color).cgColor }
    #else
    private static func cg(_ color: Color) -> CGColor { UIColor(color).cgColor }
    #endif
}

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif
