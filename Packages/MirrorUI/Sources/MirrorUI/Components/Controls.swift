import SwiftUI

// MARK: - Button styles

/// Round tool button on the camera deck (Halide's RAW / grid buttons). Holds a glyph or a short
/// caps label. `isOn` fills it with the accent.
public struct ToolButtonStyle: ButtonStyle {
    var isOn: Bool
    var size: CGFloat
    var tint: Color

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(isOn ? Palette.onAccent : tint)
            .frame(width: size, height: size)
            .background(isOn ? Palette.accent : (configuration.isPressed ? Palette.raisedHigh : Palette.raised), in: Circle())
            .overlay(Circle().strokeBorder(isOn ? Color.clear : Palette.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Capsule button for secondary actions and in-video controls.
public struct PillButtonStyle: ButtonStyle {
    var isOn: Bool
    var prominent: Bool

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(.caps, color: isOn ? Palette.onAccent : Palette.textPrimary)
            .padding(.horizontal, Space.l)
            .frame(minHeight: ControlSize.tool)
            .background(background(configuration), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Palette.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private func background(_ configuration: Configuration) -> Color {
        if isOn { return Palette.accent }
        return configuration.isPressed ? Palette.raisedHigh : (prominent ? Palette.raisedHigh : Palette.raised)
    }
}

/// Full-width action, like Halide's "Set Up Siri Shortcuts": warm white slab, dark type.
public struct PrimaryButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, destructive, accent }
    var kind: Kind

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(Fonts.groteskBold, size: 17, relativeTo: .headline))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background.opacity(configuration.isPressed ? 0.8 : 1), in: .continuous(Radius.control))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: Palette.textPrimary
        case .destructive: .white
        case .accent: Palette.onAccent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.textPrimary
        case .secondary: Palette.raised
        case .destructive: Palette.live
        case .accent: Palette.accent
        }
    }
}

public extension ButtonStyle where Self == ToolButtonStyle {
    static func tool(isOn: Bool = false, size: CGFloat = ControlSize.tool, tint: Color = Palette.textPrimary) -> ToolButtonStyle {
        ToolButtonStyle(isOn: isOn, size: size, tint: tint)
    }
}

public extension ButtonStyle where Self == PillButtonStyle {
    static func pill(isOn: Bool = false, prominent: Bool = false) -> PillButtonStyle {
        PillButtonStyle(isOn: isOn, prominent: prominent)
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle(kind: .primary) }
    static var secondary: PrimaryButtonStyle { PrimaryButtonStyle(kind: .secondary) }
    static var destructive: PrimaryButtonStyle { PrimaryButtonStyle(kind: .destructive) }
    static var accent: PrimaryButtonStyle { PrimaryButtonStyle(kind: .accent) }
}

// MARK: - Record button

/// Kino's record button: white ring, red disc that becomes a rounded square while recording.
public struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    public init(isRecording: Bool, action: @escaping () -> Void) {
        self.isRecording = isRecording
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Palette.textPrimary, lineWidth: 3.5)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 30, style: .continuous)
                    .fill(Palette.live)
                    .frame(width: isRecording ? 28 : 58, height: isRecording ? 28 : 58)
            }
            .frame(width: ControlSize.shutter, height: ControlSize.shutter)
            .animation(Motion.snappy, value: isRecording)
        }
        .buttonStyle(.plain)
        .haptic(.impact, trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Halide's shutter: a warm white disc in a ring. Used for the primary action on a deck.
public struct ShutterButton<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    public init(isActive: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isActive = isActive
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(isActive ? Palette.accent : Palette.textPrimary, lineWidth: 3.5)
                Circle()
                    .fill(isActive ? Palette.accent : Palette.textPrimary)
                    .padding(7)
                label()
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isActive ? Palette.onAccent : .black)
            }
            .frame(width: ControlSize.shutter, height: ControlSize.shutter)
            .animation(Motion.snappy, value: isActive)
        }
        .buttonStyle(ShutterPressStyle())
        .haptic(.impact, trigger: isActive)
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Segment pill

/// Halide's lens selector: small discs in a capsule; the selected one fills with the accent.
/// Works for any short options (lenses, playback speed, night mode).
public struct SegmentPill<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    public init(_ options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.options = options
        _selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    Text(label(option))
                        .type(.readout, color: selected ? Palette.onAccent : Palette.textPrimary)
                        .frame(minWidth: selected ? 38 : 32, minHeight: selected ? 38 : 32)
                        .padding(.horizontal, label(option).count > 3 ? 8 : 0)
                        .background(selected ? Palette.accent : Palette.raisedHigh, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Space.xs)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .haptic(.selection, trigger: selection)
    }
}

// MARK: - Toggle

/// Halide's toggle: dark track that fills with the accent when on.
public struct AccentToggleStyle: ToggleStyle {
    public func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.snappy) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: Space.m) {
                configuration.label
                Spacer(minLength: Space.s)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Palette.accent : Palette.raisedHigh)
                        .frame(width: 50, height: 30)
                    Circle().fill(configuration.isOn ? Palette.onAccent.opacity(0.9) : Palette.textPrimary)
                        .frame(width: 24, height: 24)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .haptic(.selection, trigger: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

public extension ToggleStyle where Self == AccentToggleStyle {
    static var accent: AccentToggleStyle { AccentToggleStyle() }
}
