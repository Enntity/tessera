import SwiftUI

/// The visual language: a dark glass control room where color means state, never decoration.
/// Every size, radius, tint, shadow and spring the chrome uses is named here.
public enum Style {
    // MARK: Surfaces

    public static let void = Color(red: 0.020, green: 0.027, blue: 0.043)
    public static let deck = Color(red: 0.035, green: 0.047, blue: 0.071)
    public static let glass = Color(red: 0.063, green: 0.078, blue: 0.110)
    public static let hairline = Color.white.opacity(0.08)
    /// The one dimming layer: behind an open panel or the palette, over a terminal that has ended.
    public static let scrim = Color.black.opacity(0.5)
    /// Over a web tile, so a white page doesn't outshine the board.
    public static let pageDim = Color.black.opacity(0.2)
    public static let terminalBackground = Color(cgColor: TerminalTheme.midnight.background.cgColor)

    // MARK: Text

    public static let ink = Color(red: 0.86, green: 0.89, blue: 0.94)
    public static let dim = Color(red: 0.52, green: 0.57, blue: 0.66)
    /// The quietest text that still reads (4.5:1 on every surface).
    public static let muted = Color(red: 0.45, green: 0.50, blue: 0.58)
    /// Not for text: tracks, idle marks.
    public static let faint = Color(red: 0.32, green: 0.36, blue: 0.44)

    // MARK: State — the only saturated colors that move, glow or fill

    public static let cyan = Color(red: 0.30, green: 0.93, blue: 0.86)
    public static let amber = Color(red: 1.00, green: 0.74, blue: 0.24)
    public static let mint = Color(red: 0.36, green: 0.92, blue: 0.56)
    public static let coral = Color(red: 1.00, green: 0.38, blue: 0.43)

    public static func state(_ activity: TileActivity) -> Color {
        switch activity {
        case .working: cyan
        case .done: mint
        case .needsInput: amber
        case .failed: coral
        case .starting, .idle, .exited: muted
        }
    }

    /// What native controls (switches, default buttons, focus rings) take in place of the system accent.
    public static let control = Color(red: 0.45, green: 0.62, blue: 0.95)

    /// A tool's own color: on its glyph and as a faint wash, never moving or glowing. Plain tools
    /// (a shell, a command, a page) have none.
    public static func accent(_ flavor: AgentFlavor) -> Color {
        switch flavor {
        case .claude, .claudeDesktop: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex, .codexDesktop: Color(red: 0.62, green: 0.78, blue: 1.00)
        case .grok: Color(red: 0.80, green: 0.82, blue: 0.86)
        case .gemini: Color(red: 0.40, green: 0.66, blue: 1.00)
        case .dsh: Color(red: 0.36, green: 0.49, blue: 1.00)
        case .omp: Color(red: 0.70, green: 0.52, blue: 1.00)
        case .opencode, .aider: Color(red: 0.95, green: 0.60, blue: 0.85)
        case .shell, .custom, .web: dim
        }
    }

    // MARK: Type

    /// The chrome's type ramp. (Tile content keeps its own, smaller sizes.)
    public enum TextSize: CGFloat, Sendable {
        /// Pills and section headers, in capitals.
        case micro = 8.5
        /// Ages, paths, counts, machine numbers.
        case caption = 10
        /// Tile titles, chips, tabs, rows, buttons.
        case label = 11.5
        case body = 13
        /// The palette's field.
        case title = 17
        /// The empty board.
        case display = 20
    }

    public static let micro = ui(.micro, .bold)
    public static let microTracking: CGFloat = 0.6
    public static let caption = mono(.caption)
    public static let label = ui(.label, .semibold)
    public static let body = ui(.body)
    public static let title = ui(.title)
    public static let display = ui(.display, .semibold)

    public static func ui(_ size: TextSize, _ weight: Font.Weight = .regular) -> Font { ui(size.rawValue, weight) }
    public static func mono(_ size: TextSize, _ weight: Font.Weight = .regular) -> Font { mono(size.rawValue, weight) }

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Space, shape, tint

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        /// Between tiles, and inside a card.
        public static let gutter: CGFloat = 10
        /// Every chrome inset: the board, the bars, the sidebar, a panel's content.
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
    }

    public enum Radius {
        /// Bubbles inside a thumbnail.
        public static let xs: CGFloat = 4
        /// Fields and icon wells.
        public static let s: CGFloat = 6
        /// Tiles, cards, chips, rows.
        public static let m: CGFloat = 10
        /// What floats: the open panel, the palette; a docked tile's panel.
        public static let l: CGFloat = 16
    }

    /// Every rounded corner is continuous.
    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// How strongly a state or tool color tints what it fills or outlines.
    public enum Tint {
        public static let wash = 0.06
        public static let fill = 0.14
        public static let strong = 0.24
        public static let stroke = 0.35
    }

    public enum Neutral {
        public static let hover = ink.opacity(0.06)
        public static let selected = ink.opacity(0.10)
        public static let border = ink.opacity(0.16)
        /// A border under the pointer.
        public static let borderHover = ink.opacity(0.28)
        public static let focus = ink.opacity(0.6)
        /// Behind the letters the filter found in a title.
        public static let found = ink.opacity(0.24)
    }

    // MARK: Motion

    public enum Motion {
        /// Hover, the palette.
        public static let quick = Animation.spring(duration: 0.2)
        /// Tabs, the sidebar, tiles coming, going and moving, privacy.
        public static let standard = Animation.spring(duration: 0.3)
        /// A panel opening out of its tile, and going back into it.
        public static let zoom = Animation.spring(duration: 0.38, bounce: 0.1)
        /// Meters, rings, numbers.
        public static let data = Animation.smooth(duration: 0.5)
    }

    // MARK: Metrics

    public enum Metrics {
        public static let hud: CGFloat = 44
        /// The row under the top bar: tabs over the board, a heading over the sidebar.
        public static let strip: CGFloat = 36
        /// Every control in the bars, and every button.
        public static let control: CGFloat = 28
        public static let panelHeader: CGFloat = 40
        public static let sidebar: CGFloat = 290
        /// The Needs-you lane.
        public static let lane: CGFloat = 220
        /// The watch dock: as wide as it starts, as narrow as it gets, and the least it leaves the board.
        public static let dock: CGFloat = 480
        public static let dockMin: CGFloat = 320
        public static let boardMin: CGFloat = 300
        /// A docked tile's header.
        public static let dockHeader: CGFloat = 32
        /// The grip the dock is resized by: how wide its hold is, and the mark on it.
        public static let grip = CGSize(width: 10, height: 32)
        /// The least room the tabs keep in their strip when the filter's chips want it.
        public static let tabs: CGFloat = 220
        /// The filter field in the top bar: as wide as it gets, and as narrow.
        public static let filter: CGFloat = 260
        public static let filterMin: CGFloat = 120
        /// A state's dot.
        public static let dot: CGFloat = 5
        /// How tall a one-tap answer's key is, in a row of the lane.
        public static let key: CGFloat = 20
        /// A load's sparkline on a machine chip; a chip stacks two in a control's height.
        public static let spark = CGSize(width: 36, height: 8)
        /// A selected tile's ring, and the gap between it and the tile's edge.
        public static let ring: CGFloat = 2
    }

    /// The shadows there are.
    public enum Elevation {
        /// A tile on the board.
        case tile
        /// What floats over the board.
        case overlay
        /// A lit mark: a dot, a meter.
        case glow(Color)
        /// A tile that needs the user.
        case attention(Color)

        var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
            switch self {
            case .tile: (.black.opacity(0.4), 6, 3)
            case .overlay: (.black.opacity(0.6), 44, 18)
            case .glow(let color): (color.opacity(0.6), 3, 0)
            case .attention(let color): (color.opacity(Tint.stroke), 14, 0)
            }
        }
    }
}

public extension View {
    func elevation(_ elevation: Style.Elevation) -> some View {
        let shadow = elevation.shadow
        return self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

public extension Date {
    /// "now", "12s", "4m", "3h", "2d" — compact enough for a card corner.
    func shortAge(now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(self))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

public extension Int {
    /// 1_234_567 → "1.2M".
    var compactTokens: String {
        switch self {
        case ..<1000: "\(self)"
        case ..<1_000_000: String(format: "%.0fk", Double(self) / 1000)
        default: String(format: "%.1fM", Double(self) / 1_000_000)
        }
    }
}

private struct PrivacyKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MotionKey: EnvironmentKey {
    static let defaultValue = true
}

private struct HighlightKey: EnvironmentKey {
    static let defaultValue = ""
}

public extension EnvironmentValues {
    /// Privacy mode: content keeps its shape and motion but can't be read (for screenshots and video).
    var tesseraPrivacy: Bool {
        get { self[PrivacyKey.self] }
        set { self[PrivacyKey.self] = newValue }
    }

    /// What the board's filter is looking for: tiles light it up where their titles have it.
    var tesseraHighlight: String {
        get { self[HighlightKey.self] }
        set { self[HighlightKey.self] = newValue }
    }

    /// Off for tiles out of view: their continuous effects (sweep, pulse, typing dots) stop.
    var tesseraMotion: Bool {
        get { self[MotionKey.self] }
        set { self[MotionKey.self] = newValue }
    }
}

public extension String {
    /// Privacy mode: every word becomes a solid bar of the same length, keeping the shape and color
    /// of the text but none of its content — the same word blocks as an obscured terminal.
    func obscured(_ on: Bool) -> String {
        guard on else { return self }
        return String(map { $0.isWhitespace ? $0 : "▆" })
    }
}
