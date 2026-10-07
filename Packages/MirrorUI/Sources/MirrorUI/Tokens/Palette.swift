import SwiftUI

/// MirrorMirror's colour tokens. Dark only, like a camera body: true black frame, near-black
/// panels, warm white type, one signal accent for "active", and LED colours for status.
///
/// Use the semantic names (`surface`, `textSecondary`, `live`) in app code, never raw hex.
public enum Palette {
    // MARK: Surfaces (back to front)

    /// Behind everything: the camera body. Pure black so OLED pixels switch off.
    public static let frame = Color(hex: 0x000000)
    /// Screen background for lists and sheets.
    public static let canvas = Color(hex: 0x0A0A0B)
    /// Grouped panels and cards.
    public static let surface = Color(hex: 0x161618)
    /// Controls sitting on a panel: tool buttons, chips, segmented pills.
    public static let raised = Color(hex: 0x232326)
    /// Pressed or selected-but-not-active controls.
    public static let raisedHigh = Color(hex: 0x2E2E32)

    // MARK: Lines

    public static let hairline = Color.white.opacity(0.08)
    public static let stroke = Color.white.opacity(0.14)
    /// Top-edge highlight that makes panels read as machined, not flat.
    public static let bevel = Color.white.opacity(0.06)

    // MARK: Type

    public static let textPrimary = Color(hex: 0xF2F1EC)
    public static let textSecondary = Color(hex: 0xF2F1EC).opacity(0.62)
    public static let textTertiary = Color(hex: 0xF2F1EC).opacity(0.38)
    public static let textDisabled = Color(hex: 0xF2F1EC).opacity(0.22)

    // MARK: Signal

    /// The one accent. Means "active / selected / on" and nothing else.
    public static let accent = Color(hex: 0xEEED7C)
    /// Type and glyphs drawn on top of `accent`.
    public static let onAccent = Color(hex: 0x16160A)
    /// Live, recording, needles, destructive.
    public static let live = Color(hex: 0xFF453A)
    /// Healthy LEDs, connected, charging.
    public static let ok = Color(hex: 0x32D74B)
    /// Warnings: warm, low battery, weak connection.
    public static let warn = Color(hex: 0xFF9F0A)
    /// Informational marks: data bars, links between devices.
    public static let info = Color(hex: 0x5AA9FF)
    /// Night vision.
    public static let night = Color(hex: 0x9C98FF)
}

public extension Color {
    /// `Color(hex: 0xEEED7C)`; sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
