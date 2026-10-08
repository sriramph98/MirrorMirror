import SwiftUI

/// A code someone reads off this screen and types on another device: large mono groups on a
/// black plate inside focus brackets. Pass it already grouped ("482 913", "ABCD-2345").
public struct CodePlate: View {
    let code: String
    let size: CGFloat

    public init(_ code: String, size: CGFloat = 40) {
        self.code = code
        self.size = size
    }

    public var body: some View {
        Text(code)
            .font(.custom(Fonts.monoBold, size: size, relativeTo: .largeTitle))
            .tracking(size * 0.12)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.l)
            .background(Palette.frame, in: .continuous(Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .focusBrackets(Palette.accent, length: Space.l, inset: -Space.s)
            .padding(Space.s)
            .accessibilityElement()
            .accessibilityLabel("Code")
            // Read character by character, not as a number.
            .accessibilityValue(code.filter { !$0.isWhitespace && $0 != "-" }.map(String.init).joined(separator: " "))
    }
}

/// Where a code is typed: large centred mono text on a black well, accent edge while focused.
public struct CodeField: View {
    @Binding var text: String
    let placeholder: String
    let numeric: Bool
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, numeric: Bool) {
        self.placeholder = placeholder
        _text = text
        self.numeric = numeric
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .font(.custom(Fonts.monoBold, size: 30, relativeTo: .title))
            .tracking(4)
            .multilineTextAlignment(.center)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.characters)
            .keyboardType(numeric ? .numberPad : .asciiCapable)
            .textContentType(.oneTimeCode)
            #endif
            .focused($focused)
            .padding(Space.m)
            .background(Palette.frame, in: .continuous(Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(focused ? Palette.accent : Palette.hairline, lineWidth: 1))
            .onAppear { focused = true }
    }
}
