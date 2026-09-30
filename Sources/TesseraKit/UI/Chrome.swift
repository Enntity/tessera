import SwiftUI

/// A one-point rule: across by default, or down.
public struct Hairline: View {
    let axis: Axis

    public init(_ axis: Axis = .horizontal) { self.axis = axis }

    public var body: some View {
        Rectangle().fill(Style.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

public extension View {
    /// Chrome (the top bar, the sidebar): the deck, a little see-through, ruled off along `edge`.
    func chromeSurface(rule edge: Edge) -> some View {
        background(Style.deck.opacity(0.7))
            .overlay(alignment: Alignment(edge)) { Hairline(edge == .top || edge == .bottom ? .horizontal : .vertical) }
    }

    /// What floats over the board (the open panel, the palette, a toast).
    func overlaySurface<S: InsettableShape>(_ shape: S = Style.shape(Style.Radius.l)) -> some View {
        background(Style.deck)
            .clipShape(shape)
            // Left to take clicks, an outline swallows those on what it surrounds.
            .overlay(shape.strokeBorder(Style.Neutral.border).allowsHitTesting(false))
            .elevation(.overlay)
    }

    /// A card in a column (an account, the iPhone link).
    func cardSurface() -> some View {
        background(Style.glass.opacity(0.6), in: Style.shape(Style.Radius.m))
            .overlay(Style.shape(Style.Radius.m).strokeBorder(Style.hairline))
    }
}

private extension Alignment {
    init(_ edge: Edge) {
        switch edge {
        case .top: self = .top
        case .bottom: self = .bottom
        case .leading: self = .leading
        case .trailing: self = .trailing
        }
    }
}

/// A state's mark: a small dot in its color, lit where it calls for the eye.
public struct Dot: View {
    let color: Color
    let lit: Bool

    public init(_ color: Color, lit: Bool = false) {
        self.color = color
        self.lit = lit
    }

    public var body: some View {
        let dot = Circle().fill(color).frame(width: Style.Metrics.dot, height: Style.Metrics.dot)
        if lit { dot.elevation(.glow(color)) } else { dot }
    }
}

/// One phase for every age on show, so their updates land together.
private let ageClockStart = Date()

/// How long ago something last happened ("4m"), kept current.
public struct Age: View {
    let date: Date

    public init(of date: Date) { self.date = date }

    public var body: some View {
        TimelineView(.periodic(from: ageClockStart, by: 15)) { ctx in Text(date.shortAge(now: ctx.date)) }
    }
}

public extension Text {
    /// Pills and section headers: small capitals, spaced out.
    func micro() -> some View {
        font(Style.micro).tracking(Style.microTracking).textCase(.uppercase)
    }
}

/// The one button: a capsule. `primary` is the action a view is there for (ink, so that no state
/// color is spent on it); the rest are quiet. Both are solid, to read over whatever is behind.
public struct CapsuleButtonStyle: ButtonStyle {
    let primary: Bool

    public init(primary: Bool = false) { self.primary = primary }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Style.label)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(primary ? Style.void : Style.ink)
            .padding(.horizontal, Style.Space.l)
            .frame(height: Style.Metrics.control)
            .background(primary ? Style.ink : Style.glass, in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? .clear : Style.Neutral.border))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Style.Motion.quick, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsulePrimary: CapsuleButtonStyle { CapsuleButtonStyle(primary: true) }
}

/// A fact about what is open, as a quiet chip (a model, a context size).
public struct Tag: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text).font(Style.caption).foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.m).padding(.vertical, Style.Space.xs)
            .background(Style.glass, in: Capsule())
    }
}
