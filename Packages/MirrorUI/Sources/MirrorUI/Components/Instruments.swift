import SwiftUI

// MARK: - Gauge

/// Analogue dial with tick marks and a red needle (7ahang's radio dial / Halide's meter).
/// Use for one value with a meaningful range: battery, storage, temperature, signal.
public struct InstrumentGauge: View {
    let value: Double            // 0...1
    let label: String
    let valueText: String
    let tint: Color
    let ticks: Int

    public init(value: Double, label: String, valueText: String, tint: Color = Palette.live, ticks: Int = 24) {
        self.value = min(1, max(0, value))
        self.label = label
        self.valueText = valueText
        self.tint = tint
        self.ticks = ticks
    }

    /// The dial sweeps 240°, open at the bottom.
    private let start = Angle.degrees(150)
    private let sweep = 240.0

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            ZStack {
                Circle().fill(Palette.raised)
                Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                // Ticks
                ForEach(0...ticks, id: \.self) { i in
                    let fraction = Double(i) / Double(ticks)
                    let major = i % 6 == 0
                    let lit = fraction <= value
                    Capsule()
                        .fill(lit ? Palette.textPrimary : Palette.textTertiary)
                        .frame(width: major ? 2 : 1, height: major ? radius * 0.16 : radius * 0.09)
                        .offset(y: -radius * 0.78)
                        .rotationEffect(.degrees(start.degrees + 90 + sweep * fraction))
                }
                // Needle
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: radius * 0.72)
                    .offset(y: -radius * 0.36)
                    .rotationEffect(.degrees(start.degrees + 90 + sweep * value))
                    .shadow(color: tint.opacity(0.6), radius: 3)
                Circle().fill(Palette.surface).frame(width: radius * 0.42)
                Circle().fill(tint).frame(width: radius * 0.14)
                VStack(spacing: 0) {
                    Spacer()
                    Text(valueText).type(.readout, color: Palette.textPrimary)
                    Text(label).type(.caps, color: Palette.textTertiary)
                }
                .padding(.bottom, radius * 0.12)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth, value: value)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }
}

// MARK: - Level meter

/// Segmented LED meter (Kino's audio meter). Green, then amber, then red.
public struct LevelMeter: View {
    let level: Double   // 0...1
    let segments: Int
    let axis: Axis

    public init(level: Double, segments: Int = 12, axis: Axis = .horizontal) {
        self.level = min(1, max(0, level))
        self.segments = segments
        self.axis = axis
    }

    public var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        layout {
            ForEach(0..<segments, id: \.self) { i in
                let index = axis == .horizontal ? i : segments - 1 - i
                let threshold = Double(index + 1) / Double(segments)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(threshold).opacity(level >= threshold - 0.5 / Double(segments) ? 1 : 0.18))
                    .frame(width: axis == .horizontal ? 3 : 12, height: axis == .horizontal ? 12 : 3)
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

// MARK: - Tick ruler

/// Halide's focus/exposure dial: a ruler of ticks that slides under a fixed centre mark.
/// Drag to change the value; labels every `labelEvery` steps.
public struct TickRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let labelEvery: Int
    let format: (Double) -> String
    let spacing: CGFloat

    @State private var dragStart: Double?
    /// Decided on the first movement: horizontal drags turn the dial, vertical ones scroll the page.
    @State private var dragIsHorizontal: Bool?

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, labelEvery: Int = 5,
                spacing: CGFloat = 9, format: @escaping (Double) -> String = { String(format: "%.1f", $0) }) {
        _value = value
        self.range = range
        self.step = step
        self.labelEvery = labelEvery
        self.format = format
        self.spacing = spacing
    }

    public var body: some View {
        GeometryReader { geo in
            let steps = Int(((range.upperBound - range.lowerBound) / step).rounded())
            let offset = CGFloat((value - range.lowerBound) / step) * spacing
            ZStack(alignment: .top) {
                // The sliding scale
                ZStack(alignment: .topLeading) {
                    ForEach(0...steps, id: \.self) { i in
                        let major = i % labelEvery == 0
                        VStack(spacing: 4) {
                            Rectangle()
                                .fill(major ? Palette.textPrimary : Palette.textTertiary)
                                .frame(width: 1, height: major ? 14 : 8)
                            if major {
                                Text(format(range.lowerBound + Double(i) * step))
                                    .type(.readout, color: Palette.textTertiary)
                                    .fixedSize()
                            }
                        }
                        .frame(width: 1)
                        .offset(x: CGFloat(i) * spacing)
                    }
                }
                // Lay the scale out from the leading edge, then slide it so `value` sits under the mark.
                .frame(width: geo.size.width, alignment: .topLeading)
                .offset(x: geo.size.width / 2 - offset)
                .padding(.top, 14)
                // Fixed centre mark and current value
                VStack(spacing: 2) {
                    Text(format(value)).type(.readout, color: Palette.accent)
                    Rectangle().fill(Palette.accent).frame(width: 2, height: 22)
                }
                .offset(y: -4)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        if dragIsHorizontal == nil {
                            dragIsHorizontal = abs(drag.translation.width) > abs(drag.translation.height)
                        }
                        guard dragIsHorizontal == true else { return }
                        let start = dragStart ?? value
                        dragStart = start
                        let raw = start - Double(drag.translation.width / spacing) * step
                        let snapped = (raw / step).rounded() * step
                        let clamped = min(range.upperBound, max(range.lowerBound, snapped))
                        if clamped != value { value = clamped }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragIsHorizontal = nil
                    }
            )
        }
        .frame(height: 56)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Focus brackets

/// Corner brackets (Halide's focus box). Frame anything that needs attention: a QR target,
/// a detected person, the selected event.
public struct CornerBrackets: Shape {
    var length: CGFloat

    public init(length: CGFloat = 18) { self.length = length }

    public func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = min(length, rect.width / 2, rect.height / 2)
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

public extension View {
    /// Draws accent focus brackets around the view.
    func focusBrackets(_ color: Color = Palette.accent, length: CGFloat = 18, lineWidth: CGFloat = 2, inset: CGFloat = -6) -> some View {
        overlay(CornerBrackets(length: length).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).padding(inset))
    }
}

// MARK: - Viewfinder

/// The live-picture frame: rounded, hairline-edged, black behind the image, with four overlay
/// slots for readouts in the corners (Halide/Kino put their technical data there).
public struct Viewfinder<Content: View, TL: View, TR: View, BL: View, BR: View>: View {
    let content: Content
    let topLeading: TL
    let topTrailing: TR
    let bottomLeading: BL
    let bottomTrailing: BR
    let radius: CGFloat

    public init(radius: CGFloat = Radius.viewfinder,
                @ViewBuilder content: () -> Content,
                @ViewBuilder topLeading: () -> TL = { EmptyView() },
                @ViewBuilder topTrailing: () -> TR = { EmptyView() },
                @ViewBuilder bottomLeading: () -> BL = { EmptyView() },
                @ViewBuilder bottomTrailing: () -> BR = { EmptyView() }) {
        self.content = content()
        self.topLeading = topLeading()
        self.topTrailing = topTrailing()
        self.bottomLeading = bottomLeading()
        self.bottomTrailing = bottomTrailing()
        self.radius = radius
    }

    public var body: some View {
        ZStack {
            Palette.frame
            content
        }
        .clipShape(.continuous(radius))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .overlay(alignment: .topLeading) { topLeading.padding(Space.m) }
        .overlay(alignment: .topTrailing) { topTrailing.padding(Space.m) }
        .overlay(alignment: .bottomLeading) { bottomLeading.padding(Space.m) }
        .overlay(alignment: .bottomTrailing) { bottomTrailing.padding(Space.m) }
    }
}
