import SwiftUI

// Halide-style settings: grouped dark panels on black, a letterspaced caps title, accent
// toggles, hairline separators. Built from plain stacks so it reads the same on iPhone and iPad.

// MARK: - Sheet header

/// Top bar for sheets and pushed screens: round back/close button, letterspaced caps title,
/// optional trailing action.
public struct SheetHeader<Trailing: View>: View {
    let title: String
    let leadingSymbol: String?
    let leadingAction: (() -> Void)?
    let trailing: Trailing

    public init(_ title: String, leadingSymbol: String? = "xmark", leadingAction: (() -> Void)? = nil,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.leadingSymbol = leadingSymbol
        self.leadingAction = leadingAction
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            Text(title).type(.navTitle).lineLimit(1).padding(.horizontal, 60)
            HStack {
                if let leadingSymbol, let leadingAction {
                    Button(action: leadingAction) { Image(systemName: leadingSymbol) }
                        .buttonStyle(.tool(size: 40))
                        .accessibilityLabel(leadingSymbol == "chevron.left" ? "Back" : "Close")
                }
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }
}

// MARK: - Sections

/// A titled group of rows in a panel, with an optional footer explanation.
public struct SettingsSection<Content: View>: View {
    let title: String?
    let symbol: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    public init(_ title: String? = nil, symbol: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.footer = footer
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                HStack(spacing: Space.s) {
                    if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(Palette.textSecondary) }
                    Text(title).type(.caps)
                }
                .padding(.horizontal, Space.xs)
            }
            VStack(spacing: 0) {
                // iOS 18 subview API: hairlines between rows, none after the last.
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        row
                        if index < rows.count - 1 {
                            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, Space.l)
                        }
                    }
                }
            }
            .panel(padding: nil)
            if let footer {
                Text(footer).type(.footnote, color: Palette.textTertiary).padding(.horizontal, Space.xs)
            }
        }
    }
}

// MARK: - Rows

/// Label (+ optional detail) on the left, anything on the right.
public struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let symbol: String?
    let trailing: Trailing

    public init(_ title: String, detail: String? = nil, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).type(.body)
                if let detail { Text(detail).type(.footnote, color: Palette.textTertiary) }
            }
            Spacer(minLength: Space.s)
            trailing
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Row with an accent toggle.
public struct ToggleRow: View {
    let title: String
    let detail: String?
    let symbol: String?
    @Binding var isOn: Bool

    public init(_ title: String, detail: String? = nil, symbol: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        _isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Space.m) {
                if let symbol {
                    Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Palette.textSecondary).frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).type(.body)
                    if let detail { Text(detail).type(.footnote, color: Palette.textTertiary) }
                }
            }
        }
        .toggleStyle(.accent)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: 52)
    }
}

/// Row whose value is chosen from a menu (Halide's "Default ⌃⌄").
public struct MenuRow<Value: Hashable>: View {
    let title: String
    let symbol: String?
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    public init(_ title: String, symbol: String? = nil, options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.title = title
        self.symbol = symbol
        self.options = options
        _selection = selection
        self.label = label
    }

    public var body: some View {
        #if os(watchOS)
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .padding(.horizontal, Space.l)
        #else
        SettingRow(title, symbol: symbol) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(selection)).type(.readoutLarge, color: Palette.textSecondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        #endif
    }
}

/// Row with a tick ruler underneath its label (sensitivity, storage cap, zoom).
public struct RulerRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let labelEvery: Int
    let format: (Double) -> String

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, labelEvery: Int = 5,
                format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.labelEvery = labelEvery
        self.format = format
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(title).type(.body)
                Spacer()
                Text(format(value)).type(.readoutLarge, color: Palette.accent)
            }
            TickRuler(value: $value, in: range, step: step, labelEvery: labelEvery, format: format)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }
}

/// Row that navigates or performs an action, with a chevron or value.
public struct ActionRow: View {
    let title: String
    let value: String?
    let symbol: String?
    let role: ButtonRole?
    let action: () -> Void

    public init(_ title: String, value: String? = nil, symbol: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            SettingRow(title, symbol: symbol) {
                if let value { Text(value).type(.readoutLarge, color: Palette.textSecondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.textTertiary)
            }
            .foregroundStyle(role == .destructive ? Palette.live : Palette.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

/// Plain label/value row.
public struct ValueRow: View {
    let title: String
    let value: String
    let symbol: String?
    let valueColor: Color

    public init(_ title: String, value: String, symbol: String? = nil, valueColor: Color = Palette.textSecondary) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.valueColor = valueColor
    }

    public var body: some View {
        SettingRow(title, symbol: symbol) {
            Text(value).type(.readoutLarge, color: valueColor).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Feedback

/// Transient message capsule.
public struct Toast: View {
    let text: String
    let symbol: String?

    public init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Palette.accent) }
            Text(text).type(.callout)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Empty and error states: a framed glyph, a title and one sentence.
public struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    let actions: Actions

    public init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 72, height: 72)
                .focusBrackets(Palette.textTertiary, length: 14, lineWidth: 1.5, inset: 0)
            Text(title).type(.title).multilineTextAlignment(.center)
            Text(message).type(.callout, color: Palette.textSecondary).multilineTextAlignment(.center)
            actions
        }
        .padding(Space.xl)
        .frame(maxWidth: 420)
    }
}
