import SwiftUI

/// The visual language: a dark glass control room where color means state, never decoration.
public enum Style {
    public static let void = Color(red: 0.020, green: 0.027, blue: 0.043)
    public static let deck = Color(red: 0.035, green: 0.047, blue: 0.071)
    public static let glass = Color(red: 0.063, green: 0.078, blue: 0.110)
    public static let hairline = Color.white.opacity(0.08)
    public static let ink = Color(red: 0.86, green: 0.89, blue: 0.94)
    public static let dim = Color(red: 0.52, green: 0.57, blue: 0.66)
    public static let faint = Color(red: 0.32, green: 0.36, blue: 0.44)

    public static let cyan = Color(red: 0.30, green: 0.93, blue: 0.86)
    public static let amber = Color(red: 1.00, green: 0.74, blue: 0.24)
    public static let mint = Color(red: 0.36, green: 0.92, blue: 0.56)
    public static let coral = Color(red: 1.00, green: 0.38, blue: 0.43)
    public static let violet = Color(red: 0.70, green: 0.52, blue: 1.00)
    public static let sky = Color(red: 0.40, green: 0.66, blue: 1.00)

    public static let terminalBackground = Color(red: 10 / 255, green: 13 / 255, blue: 20 / 255)

    public static func accent(_ flavor: AgentFlavor) -> Color {
        switch flavor {
        case .claude, .claudeDesktop: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex, .codexDesktop: Color(red: 0.62, green: 0.78, blue: 1.00)
        case .grok: Color(red: 0.80, green: 0.82, blue: 0.86)
        case .gemini: sky
        case .omp: violet
        case .opencode, .aider, .custom: Color(red: 0.95, green: 0.60, blue: 0.85)
        case .shell: cyan
        case .web: violet
        }
    }

    public static func state(_ activity: TileActivity) -> Color {
        switch activity {
        case .starting: dim
        case .working: cyan
        case .idle: faint
        case .done: mint
        case .needsInput: amber
        case .exited: faint
        case .failed: coral
        }
    }

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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

public extension EnvironmentValues {
    /// Privacy mode: content keeps its shape and motion but can't be read (for screenshots and video).
    var tesseraPrivacy: Bool {
        get { self[PrivacyKey.self] }
        set { self[PrivacyKey.self] = newValue }
    }
}

public extension String {
    /// Privacy mode: every word becomes a solid bar of the same length, keeping the shape and color
    /// of the text but none of its content — the same look as a terminal minimap.
    func obscured(_ on: Bool) -> String {
        guard on else { return self }
        return String(map { $0.isWhitespace ? $0 : "▆" })
    }
}
