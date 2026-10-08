import SwiftUI

// MARK: - Panel

/// The basic container: a near-black, softly bevelled card, like a machined plate.
public struct PanelBackground: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var padding: CGFloat?

    public func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(fill, in: .continuous(radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Palette.stroke, Palette.hairline, Palette.hairline.opacity(0.4)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            }
    }
}

public extension View {
    /// Wraps content in a panel. `padding: nil` leaves spacing to the content.
    func panel(radius: CGFloat = Radius.panel, fill: Color = Palette.surface, padding: CGFloat? = Space.l) -> some View {
        modifier(PanelBackground(radius: radius, fill: fill, padding: padding))
    }

    /// Full-screen canvas background, dark only.
    func canvasBackground(_ color: Color = Palette.canvas) -> some View {
        background(color.ignoresSafeArea())
    }

    /// Constrains forms and lists to a readable width on iPad, centred.
    func readableWidth(_ width: CGFloat = ControlSize.readableWidth) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

// MARK: - Badge

/// Small rectangular badge: "AUTO", "•REC", "2K". The camera-body nameplate.
public struct Badge: View {
    public enum Style { case outline, filled, accent, recording, live }

    let text: String
    let style: Style

    public init(_ text: String, style: Style = .outline) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            if style == .recording || style == .live {
                Circle().fill(Palette.live).frame(width: 6, height: 6)
            }
            Text(text).type(.readout, color: foreground)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(background, in: .continuous(Radius.badge))
        .overlay {
            if style == .outline {
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch style {
        case .outline: Palette.textSecondary
        case .filled: Palette.textPrimary
        case .accent: Palette.onAccent
        case .recording: Color.black
        case .live: Palette.textPrimary
        }
    }

    private var background: Color {
        switch style {
        case .outline: Color.black.opacity(0.35)
        case .filled, .live: Palette.raised
        case .accent: Palette.accent
        case .recording: Palette.textPrimary
        }
    }
}

// MARK: - LED

/// Status light with an optional caps label: ● BATT, ● LIVE. Colour carries the state, so the
/// label (or an accessibility label) must say it too.
public struct LED: View {
    let color: Color
    let label: String?
    let pulsing: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ color: Color, label: String? = nil, pulsing: Bool = false) {
        self.color = color
        self.label = label
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
                .opacity(pulsing && dim ? 0.35 : 1)
            if let label {
                Text(label).type(.caps)
            }
        }
        .onAppear {
            guard pulsing, !reduceMotion else { return }
            withAnimation(Motion.pulse) { dim = true }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Readouts

/// Technical line of values separated by dots: "1080 · 30 · HEVC".
public struct ReadoutLine: View {
    let items: [String]
    let color: Color

    public init(_ items: [String], color: Color = Palette.textSecondary) {
        self.items = items
        self.color = color
    }

    public var body: some View {
        Text(items.joined(separator: " · ")).type(.readout, color: color).lineLimit(1)
    }
}

/// Stacked value + caption, as on Halide's exposure readout ("7840" over "1/15").
public struct Readout: View {
    let value: String
    let caption: String
    let alignment: HorizontalAlignment
    let color: Color

    public init(_ value: String, caption: String, alignment: HorizontalAlignment = .leading, color: Color = Palette.textPrimary) {
        self.value = value
        self.caption = caption
        self.alignment = alignment
        self.color = color
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(value).type(.readout, color: color)
            Text(caption).type(.readout, color: Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Big numeral with a small unit and optional caption, 7ahang style: "142" "H LEFT".
public struct Numeral: View {
    let value: String
    let unit: String?
    let caption: String?
    let color: Color

    public init(_ value: String, unit: String? = nil, caption: String? = nil, color: Color = Palette.textPrimary) {
        self.value = value
        self.unit = unit
        self.caption = caption
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).type(.numeral, color: color)
                if let unit { Text(unit).type(.headline, color: Palette.textSecondary) }
            }
            if let caption { Text(caption).type(.caps) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chips

/// Rounded stat chip: "L 72%", "CASE 63%", with an optional leading symbol or tag.
public struct StatChip: View {
    let tag: String?
    let symbol: String?
    let text: String
    let tint: Color

    public init(_ text: String, tag: String? = nil, symbol: String? = nil, tint: Color = Palette.textPrimary) {
        self.text = text
        self.tag = tag
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let tag {
                Text(tag).type(.caps, color: Palette.textSecondary)
            }
            if let symbol {
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            }
            Text(text).type(.readout, color: tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Wordmark

/// The Mira nameplate.
public struct Wordmark: View {
    let size: CGFloat

    public init(size: CGFloat = 15) { self.size = size }

    /// MIRA, letterspaced, with the accent dot of a camera's tally light.
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.18) {
            Text("MIRA").foregroundStyle(Palette.textPrimary)
            Circle()
                .fill(Palette.accent)
                .frame(width: size * 0.34, height: size * 0.34)
                .shadow(color: Palette.accent.opacity(0.6), radius: size * 0.2)
        }
        .font(.custom(Fonts.groteskBold, size: size, relativeTo: .headline))
        .tracking(size * 0.32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mira")
    }
}

/// The privacy promise in one line: lock and END-TO-END ENCRYPTED. Wrap it in a button that
/// explains how (it's the app's most important claim, so it should always be one tap from proof).
public struct EncryptionBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "lock.fill").font(.caption2.weight(.bold))
            Text("End-to-end encrypted").type(.readout, color: Palette.textTertiary)
            Image(systemName: "info.circle").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End-to-end encrypted")
        .accessibilityHint("Shows how your video is protected")
    }
}
