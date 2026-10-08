import SwiftUI
import CoreText

/// Type tokens. Three voices, like the type on a camera body:
/// - **Space Grotesk** for titles, labels and big numerals (the etched markings),
/// - **JetBrains Mono** for technical readouts (the LCD),
/// - **SF Pro** for sentences, so explanations stay easy to read.
///
/// Every style scales with Dynamic Type via `relativeTo:`.
public enum TypeStyle: CaseIterable, Sendable {
    /// Hero numerals: "79.5", "23°", time remaining.
    case numeral
    /// Screen and section heroes.
    case display
    case title
    case headline
    /// Letterspaced uppercase titles: "CAPTURE", "LOOKS".
    case navTitle
    /// Small letterspaced uppercase labels: "BATT", "LIVE", section headers.
    case caps
    /// Technical readouts: "1080 · 30 · HEVC", "-6.5 METER".
    case readout
    case readoutLarge
    case body
    case callout
    case footnote

    var font: Font {
        switch self {
        case .numeral: .custom(Fonts.groteskBold, size: 44, relativeTo: .largeTitle)
        case .display: .custom(Fonts.groteskBold, size: 30, relativeTo: .largeTitle)
        case .title: .custom(Fonts.groteskBold, size: 22, relativeTo: .title2)
        case .headline: .custom(Fonts.groteskMedium, size: 17, relativeTo: .headline)
        case .navTitle: .custom(Fonts.groteskMedium, size: 16, relativeTo: .headline)
        case .caps: .custom(Fonts.groteskBold, size: 11, relativeTo: .caption)
        case .readout: .custom(Fonts.monoMedium, size: 11, relativeTo: .caption2)
        case .readoutLarge: .custom(Fonts.monoMedium, size: 15, relativeTo: .subheadline)
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        }
    }

    /// Letter spacing in points.
    var tracking: CGFloat {
        switch self {
        case .numeral: -1.2
        case .display: -0.6
        case .title: -0.3
        case .navTitle: 4
        case .caps: 1.4
        case .readout: 0.6
        case .readoutLarge: 0.3
        default: 0
        }
    }

    var isUppercase: Bool {
        switch self {
        case .navTitle, .caps, .readout: true
        default: false
        }
    }

    var defaultColor: Color {
        switch self {
        case .caps, .readout, .footnote: Palette.textSecondary
        default: Palette.textPrimary
        }
    }
}

public extension View {
    /// Applies a type style: font, tracking, case and (unless overridden later) colour.
    func type(_ style: TypeStyle, color: Color? = nil) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
            .foregroundStyle(color ?? style.defaultColor)
            .monospacedDigit()
    }
}

/// Bundled typefaces (SIL Open Font License, see Resources/Fonts).
public enum Fonts {
    public static let groteskMedium = "SpaceGrotesk-Medium"
    public static let groteskBold = "SpaceGrotesk-Bold"
    public static let monoRegular = "JetBrainsMono-Regular"
    public static let monoMedium = "JetBrainsMono-Medium"
    public static let monoBold = "JetBrainsMono-Bold"

    private static let registered: Bool = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
            ?? Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return !urls.isEmpty
    }()

    /// Call once at launch (the app's `init`). Safe to call repeatedly.
    @discardableResult
    public static func register() -> Bool { registered }
}
