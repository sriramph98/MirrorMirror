import SwiftUI

// Pieces for Live Activities: the Lock Screen banner, the Dynamic Island and the Apple Watch
// Smart Stack. Widgets render as snapshots: no hover, no haptics, no repeating animation, and
// buttons are App Intents or links, so these are plain views a widget wraps in
// `Button(intent:)` or `Link`.

public extension ControlSize {
    /// Height of a Lock Screen / expanded Dynamic Island control.
    static let activityControl: CGFloat = 40
    /// Width of the Dynamic Island's compact level meter.
    static let activityMeterSegments = 5
}

/// A Live Activity button face: symbol and caps title on a raised capsule. `isOn` lights it in
/// accent (e.g. muted), `destructive` tints it red (e.g. stop).
public struct ActivityControl: View {
    public enum Role { case normal, destructive }

    let title: String
    let symbol: String
    let isOn: Bool
    let role: Role

    public init(_ title: String, symbol: String, isOn: Bool = false, role: Role = .normal) {
        self.title = title
        self.symbol = symbol
        self.isOn = isOn
        self.role = role
    }

    private var foreground: Color {
        if isOn { return Palette.onAccent }
        return role == .destructive ? Palette.live : Palette.textPrimary
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
            Text(title)
                .type(.caps, color: foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, minHeight: ControlSize.activityControl)
        .background(isOn ? Palette.accent : Palette.raised, in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.bevel, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// One line about the latest event: symbol, label and how long ago, with the time in a mono
/// readout that the system keeps current without an update.
public struct ActivityEventLine: View {
    let symbol: String?
    let label: String?
    let date: Date?
    let placeholder: String

    public init(symbol: String?, label: String?, date: Date?, placeholder: String = "No events yet") {
        self.symbol = symbol
        self.label = label
        self.date = date
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol ?? "checkmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(label == nil ? Palette.textTertiary : Palette.accent)
                .frame(width: Space.l)
            Text(label ?? placeholder)
                .type(.headline, color: label == nil ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            if let date, label != nil {
                Text(date, style: .relative)
                    .type(.readout, color: Palette.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown instead of live values when the activity stopped receiving updates (the app was
/// closed or the phone ran out of memory). Colour and words both say it.
public struct ActivityStaleNotice: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.warn)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
