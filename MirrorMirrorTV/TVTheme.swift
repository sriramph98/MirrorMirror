import SwiftUI
import MirrorUI

// MARK: - Type at TV distance

/// MirrorUI's type styles sized for a television three metres away. Dynamic Type on tvOS only
/// scales the phone sizes by ~1.7×, which leaves 11 pt caps at 19 pt, so the same three faces
/// (Space Grotesk, JetBrains Mono, SF) get a dedicated size table here. Everything else (colour,
/// case, tracking semantics) follows `TypeStyle`.
enum TVType {
    static func size(_ style: TypeStyle) -> CGFloat {
        switch style {
        // Nothing under 29 pt: that is roughly the smallest a sofa three metres away still reads.
        case .numeral: 128
        case .display: 68
        case .title: 48
        case .headline: 37
        case .navTitle: 34
        case .caps: 29
        case .readout: 29
        case .readoutLarge: 36
        case .body: 34
        case .callout: 31
        case .footnote: 29
        }
    }

    static func font(_ style: TypeStyle) -> Font {
        switch style {
        case .numeral, .display, .title: .custom(Fonts.groteskBold, fixedSize: size(style))
        case .caps: .custom(Fonts.groteskBold, fixedSize: size(style))
        case .headline, .navTitle: .custom(Fonts.groteskMedium, fixedSize: size(style))
        case .readout, .readoutLarge: .custom(Fonts.monoMedium, fixedSize: size(style))
        case .body: .system(size: size(style))
        case .callout: .system(size: size(style))
        case .footnote: .system(size: size(style))
        }
    }

    static func tracking(_ style: TypeStyle) -> CGFloat {
        switch style {
        case .numeral: -3
        case .display: -1.2
        case .title: -0.6
        case .navTitle: 7
        case .caps: 3
        case .readout: 1.2
        case .readoutLarge: 0.8
        default: 0
        }
    }

    static func isUppercase(_ style: TypeStyle) -> Bool {
        switch style {
        case .navTitle, .caps, .readout: true
        default: false
        }
    }

    static func defaultColor(_ style: TypeStyle) -> Color {
        switch style {
        case .caps, .readout, .footnote: Palette.textSecondary
        default: Palette.textPrimary
        }
    }
}

extension View {
    /// Applies a MirrorUI type style at TV size.
    func tv(_ style: TypeStyle, color: Color? = nil) -> some View {
        self
            .font(TVType.font(style))
            .tracking(TVType.tracking(style))
            .textCase(TVType.isUppercase(style) ? .uppercase : nil)
            .foregroundStyle(color ?? TVType.defaultColor(style))
            .monospacedDigit()
    }
}

// MARK: - Layout at TV distance

/// Sizes that have no MirrorUI token yet because the package is sized for hands, not sofas.
/// Multiples of the 4-pt scale, named for what they do.
enum TVSize {
    /// Round tool buttons.
    static let tool: CGFloat = 80
    /// Pill buttons.
    static let pill: CGFloat = 68
    /// LED dot.
    static let led: CGFloat = 14
    /// Event thumbnails in lists.
    static let thumbnail = CGSize(width: 176, height: 99)
    /// Timeline side panel.
    static let panelWidth: CGFloat = 720
    /// Safe margin from the TV edges (Apple's 60/90 pt overscan guide).
    static let margin: CGFloat = 80
    /// Gap between wall tiles.
    static let gutter: CGFloat = 40
    /// How far a focused tile grows.
    static let focusScale: CGFloat = 1.03
    /// Ruler magnification: MirrorUI's TickRuler is drawn for a phone.
    static let rulerScale: CGFloat = 2.4
}
