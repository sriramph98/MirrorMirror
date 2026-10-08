import SwiftUI
import MirrorUI

// TV-sized counterparts of MirrorUI's small instruments (Badge, LED, LevelMeter, Numeral,
// EmptyState) and focus-aware button styles. Same tokens, same meanings, bigger metal.

// MARK: - Badge

struct TVBadge: View {
    let text: String
    let style: Badge.Style

    init(_ text: String, style: Badge.Style = .outline) {
        self.text = text
        self.style = style
    }

    var body: some View {
        HStack(spacing: Space.s) {
            if style == .recording || style == .live {
                Circle().fill(Palette.live).frame(width: Space.m, height: Space.m)
            }
            Text(text).tv(.readout, color: foreground)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s + Space.xxs)
        .background(background, in: .continuous(Radius.chip))
        .overlay {
            if style == .outline {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1.5)
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
        case .outline: Color.black.opacity(0.45)
        case .filled, .live: Palette.raised
        case .accent: Palette.accent
        case .recording: Palette.textPrimary
        }
    }
}

// MARK: - LED

struct TVLED: View {
    let color: Color
    let label: String?
    let pulsing: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ color: Color, label: String? = nil, pulsing: Bool = false) {
        self.color = color
        self.label = label
        self.pulsing = pulsing
    }

    var body: some View {
        HStack(spacing: Space.m) {
            Circle()
                .fill(color)
                .frame(width: TVSize.led, height: TVSize.led)
                .shadow(color: color.opacity(0.8), radius: Space.s)
                .opacity(pulsing && dim ? 0.35 : 1)
            if let label {
                Text(label).tv(.caps, color: Palette.textPrimary)
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

struct TVReadoutLine: View {
    let items: [String]
    let color: Color

    init(_ items: [String], color: Color = Palette.textSecondary) {
        self.items = items
        self.color = color
    }

    var body: some View {
        Text(items.joined(separator: " · ")).tv(.readout, color: color).lineLimit(1)
    }
}

struct TVNumeral: View {
    let value: String
    let unit: String?
    let caption: String?
    let color: Color

    init(_ value: String, unit: String? = nil, caption: String? = nil, color: Color = Palette.textPrimary) {
        self.value = value
        self.unit = unit
        self.caption = caption
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(value).tv(.numeral, color: color)
                if let unit { Text(unit).tv(.headline, color: Palette.textSecondary) }
            }
            if let caption { Text(caption).tv(.caps) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Level meter

struct TVLevelMeter: View {
    let level: Double
    let segments: Int

    init(level: Double, segments: Int = 12) {
        self.level = min(1, max(0, level))
        self.segments = segments
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<segments, id: \.self) { i in
                let threshold = Double(i + 1) / Double(segments)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(threshold).opacity(level >= threshold - 0.5 / Double(segments) ? 1 : 0.18))
                    .frame(width: Space.s, height: Space.xl)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(_ threshold: Double) -> Color {
        threshold > 0.85 ? Palette.live : threshold > 0.65 ? Palette.warn : Palette.ok
    }
}

// MARK: - Empty state

struct TVEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 160, height: 160)
                .focusBrackets(Palette.textTertiary, length: Space.xxl, lineWidth: 2.5, inset: 0)
            Text(title).tv(.display).multilineTextAlignment(.center)
            Text(message).tv(.body, color: Palette.textSecondary).multilineTextAlignment(.center)
            actions().padding(.top, Space.l)
        }
        .padding(Space.xxxl)
        .frame(maxWidth: 900)
    }
}

// MARK: - Button styles

/// Lets a button style react to the Siri Remote focus engine.
private struct FocusReader<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(isFocused) }
}

/// Capsule action at TV size. Accent when `isOn`; focus lifts it and draws an accent ring.
struct TVPillStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Palette.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { focused in
            configuration.label
                .tv(.caps, color: isOn ? Palette.onAccent : tint)
                .lineLimit(1)
                .padding(.horizontal, Space.xl)
                .frame(minHeight: TVSize.pill)
                .background(isOn ? Palette.accent : (focused ? Palette.raisedHigh : Palette.raised), in: Capsule())
                .overlay(Capsule().strokeBorder(focused ? Palette.accent : (isOn ? .clear : Palette.stroke), lineWidth: focused ? 3 : 1.5))
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 10)
                .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.08 : 1))
                .animation(Motion.snappy, value: focused)
                .animation(Motion.snappy, value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

/// Round glyph button at TV size.
struct TVToolStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Palette.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { focused in
            configuration.label
                .font(.system(size: TVSize.tool * 0.38, weight: .semibold))
                .foregroundStyle(isOn ? Palette.onAccent : tint)
                .frame(width: TVSize.tool, height: TVSize.tool)
                .background(isOn ? Palette.accent : (focused ? Palette.raisedHigh : Palette.raised), in: Circle())
                .overlay(Circle().strokeBorder(focused ? Palette.accent : (isOn ? .clear : Palette.stroke), lineWidth: focused ? 3 : 1.5))
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 10)
                .scaleEffect(configuration.isPressed ? 0.94 : (focused ? 1.1 : 1))
                .animation(Motion.snappy, value: focused)
                .animation(Motion.snappy, value: configuration.isPressed)
                .contentShape(Circle())
        }
    }
}

/// A wall tile or card: grows slightly and gets accent focus brackets.
struct TVCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { focused in
            configuration.label
                .focusBrackets(focused ? Palette.accent : .clear, length: Space.xxxl, lineWidth: 4, inset: -Space.l)
                .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: 40, y: 20)
                .scaleEffect(configuration.isPressed ? 0.99 : (focused ? TVSize.focusScale : 1))
                .animation(Motion.smooth, value: focused)
                .animation(Motion.snappy, value: configuration.isPressed)
        }
    }
}

/// A list row: raised when focused with an accent bar on the leading edge.
struct TVRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { focused in
            configuration.label
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? Palette.raisedHigh : (isSelected ? Palette.raised : .clear), in: .continuous(Radius.control))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: 4)
                        .padding(.vertical, Space.m)
                        .opacity(focused || isSelected ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.99 : (focused ? 1.015 : 1))
                .animation(Motion.snappy, value: focused)
                .animation(Motion.snappy, value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

/// Invisible: for a full-screen "stage" that only needs to receive focus and Select.
struct TVStageStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension ButtonStyle where Self == TVPillStyle {
    static func tvPill(isOn: Bool = false, tint: Color = Palette.textPrimary) -> TVPillStyle { TVPillStyle(isOn: isOn, tint: tint) }
}

extension ButtonStyle where Self == TVToolStyle {
    static func tvTool(isOn: Bool = false, tint: Color = Palette.textPrimary) -> TVToolStyle { TVToolStyle(isOn: isOn, tint: tint) }
}

extension ButtonStyle where Self == TVCardStyle {
    static var tvCard: TVCardStyle { TVCardStyle() }
}

extension ButtonStyle where Self == TVRowStyle {
    static func tvRow(isSelected: Bool = false) -> TVRowStyle { TVRowStyle(isSelected: isSelected) }
}

extension ButtonStyle where Self == TVStageStyle {
    static var tvStage: TVStageStyle { TVStageStyle() }
}

// MARK: - Scrims

/// Top and bottom gradients that keep corner readouts legible on any picture.
struct TVScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Palette.frame.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, Palette.frame.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Alert banner

/// Bracketed banner at the top of any screen: what happened, where, and a Replay that opens the
/// camera a few seconds before the event. Focus lands on Replay so one press is enough.
struct TVAlertBanner: View {
    let alert: TVRouter.Alert
    let onReplay: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xl) {
            Image(systemName: alert.event.kind.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(alert.event.kind.tvTint)
                .frame(width: 72, height: 72)
                .background(Palette.raised, in: Circle())
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(alert.event.label).tv(.title).lineLimit(1)
                HStack(spacing: Space.m) {
                    TVLED(alert.event.kind.tvTint, label: alert.camera.name)
                    Text(alert.event.date.tvClock).tv(.readout, color: Palette.textTertiary)
                }
            }
            Button(action: onReplay) { Label("Replay", systemImage: "gobackward.5") }
                .buttonStyle(.tvPill(isOn: true))
                .labelStyle(TVBarLabelStyle())
                .focused($focused)
                .padding(.leading, Space.m)
                .accessibilityHint("Opens \(alert.camera.name) from five seconds before this")
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .frame(minWidth: 760)
        .background(Palette.surface.opacity(0.96), in: .continuous(Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1.5))
        .focusBrackets(Palette.accent, length: Space.xxxl, lineWidth: 4, inset: -Space.m)
        .shadow(color: .black.opacity(0.7), radius: 48, y: 24)
        .focusSection()
        .onAppear { focused = true }
        .onChange(of: alert) { _, _ in focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(alert.event.label) at \(alert.camera.name)")
    }
}

// MARK: - Tick ruler

/// The tick dial at TV size, driven by the Siri Remote: the scale slides under a fixed accent
/// mark; left/right step `step`, quick successive swipes accelerate; Select runs `onSelect`.
/// Draws only the visible ticks (a day in 30 s steps is 2 880 of them), plus recorded coverage and
/// event marks beneath, so the ruler doubles as the timeline instrument.
struct TVTickRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Seconds between labelled (major) ticks.
    let labelEvery: Double
    /// Points per step.
    let spacing: CGFloat
    let format: (Double) -> String
    /// Which values get a labelled tick and which a medium one; defaults to spacing from the range start.
    var tickKind: ((Double) -> TickKind)?
    /// Recorded footage, as ranges in the ruler's units.
    var coverage: [ClosedRange<Double>] = []
    /// Event marks: position and colour.
    var marks: [(position: Double, color: Color)] = []
    var onSelect: () -> Void = {}
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @FocusState private var focused: Bool
    @State private var lastMove: Date = .distantPast
    @State private var rapidMoves = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 150

    enum TickKind { case minor, medium, major }

    var body: some View {
        Button(action: onSelect) {
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tvStage)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(focused ? Palette.accent : Palette.hairline, lineWidth: focused ? 3 : 1)
            .padding(-Space.s))
        .animation(reduceMotion ? nil : Motion.snappy, value: focused)
        .onMoveCommand(perform: move)
        .accessibilityElement()
        .accessibilityLabel("Time")
        .accessibilityValue(format(value))
        .accessibilityHint("Swipe left or right to move in time, press to play from here")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: onMoveUp?()
        case .down: onMoveDown?()
        case .left, .right:
            // Swipes that keep coming grow the step: 1 → 4 → 20 steps (30 s → 2 min → 10 min).
            let now = Date()
            rapidMoves = now.timeIntervalSince(lastMove) < 0.35 ? rapidMoves + 1 : 0
            lastMove = now
            let multiplier: Double = rapidMoves > 24 ? 20 : rapidMoves > 8 ? 4 : 1
            let delta = step * multiplier * (direction == .left ? -1 : 1)
            let snapped = ((value + delta) / step).rounded() * step
            value = min(range.upperBound, max(range.lowerBound, snapped))
        @unknown default: break
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let centre = size.width / 2
        let x = { (v: Double) -> CGFloat in centre + CGFloat((v - value) / step) * spacing }
        let baseline = size.height * 0.62

        // Coverage bar: recorded footage along the bottom.
        let barY = baseline + 30
        context.fill(Path(CGRect(x: 0, y: barY, width: size.width, height: 6)), with: .color(Palette.raised))
        for span in coverage {
            let x0 = max(0, x(span.lowerBound)), x1 = min(size.width, x(span.upperBound))
            guard x1 > x0 else { continue }
            context.fill(Path(roundedRect: CGRect(x: x0, y: barY, width: x1 - x0, height: 6), cornerRadius: 3),
                         with: .color(Palette.textSecondary))
        }
        // Event marks: LED dots on the bar.
        for mark in marks {
            let mx = x(mark.position)
            guard mx > -8, mx < size.width + 8 else { continue }
            let dot = CGRect(x: mx - 6, y: barY - 3, width: 12, height: 12)
            context.fill(Path(ellipseIn: dot), with: .color(mark.color))
        }

        // Ticks: only the ones on screen.
        let visibleSteps = Int(size.width / spacing / 2) + 2
        let currentStep = (value / step).rounded()
        let majorEvery = max(1, Int((labelEvery / step).rounded()))
        for i in -visibleSteps...visibleSteps {
            let stepIndex = Int(currentStep) + i
            let v = Double(stepIndex) * step
            guard range.contains(v) else { continue }
            let tx = x(v)
            let kind = tickKind?(v) ?? (stepIndex % majorEvery == 0 ? .major : stepIndex % max(1, majorEvery / 2) == 0 ? .medium : .minor)
            let major = kind == .major
            let medium = kind == .medium
            let tickHeight: CGFloat = major ? 34 : medium ? 22 : 12
            let color = major ? Palette.textPrimary : Palette.textTertiary
            context.fill(Path(CGRect(x: tx - (major ? 1.5 : 1), y: baseline - tickHeight, width: major ? 3 : 2, height: tickHeight)),
                         with: .color(color))
            if major {
                let label = Text(format(v)).font(.custom(Fonts.monoMedium, fixedSize: 29)).foregroundStyle(Palette.textTertiary)
                context.draw(context.resolve(label), at: CGPoint(x: tx, y: baseline - tickHeight - 24), anchor: .center)
            }
        }

        // Fixed centre mark.
        context.fill(Path(roundedRect: CGRect(x: centre - 2, y: baseline - 54, width: 4, height: 92), cornerRadius: 2),
                     with: .color(Palette.accent))
        var glow = context
        glow.addFilter(.shadow(color: Palette.accent.opacity(0.7), radius: 8))
        glow.fill(Path(ellipseIn: CGRect(x: centre - 7, y: baseline + 30, width: 14, height: 14)), with: .color(Palette.accent))
    }
}
