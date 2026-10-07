import SwiftUI
import MirrorUI

/// Under (or beside) the live picture: the time-window selector, an instrument-style strip of
/// recorded footage with event marks and a playback needle, the playback row, and the event list.
struct TimelinePanel: View {
    @ObservedObject var connection: CameraConnection
    let onExport: () -> Void
    @State private var window: TimeInterval = 3600
    @State private var filter: EventKind?
    @State private var selectedEvent: UUID?

    private static let windows: [TimeInterval] = [3600, 6 * 3600, 24 * 3600, 7 * 24 * 3600]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                instrument
                eventSection
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .readableWidth(720)
        }
        .scrollIndicators(.hidden)
        .onAppear { connection.refreshTimeline() }
        .onChange(of: connection.phase) { _, phase in if phase == .connected { connection.refreshTimeline() } }
        .onChange(of: connection.playback.isLive) { _, live in if live { selectedEvent = nil } }
        .task {
            // New segments are only announced on request; keep the strip current while it's on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if connection.phase == .connected { connection.refreshTimeline() }
            }
        }
    }

    // MARK: Instrument

    private var instrument: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("Timeline").type(.caps).padding(.leading, Space.xs)
                Spacer(minLength: Space.s)
                SegmentPill(Self.windows, selection: $window, label: Self.windowLabel)
                    .accessibilityLabel("Time window")
            }

            TimelineStrip(segments: connection.segments, events: connection.events, window: window,
                          position: connection.playback.isLive ? nil : connection.playback.date) { date in
                // Playback is served by the camera; seeking while offline would only fake a state.
                if connection.phase == .connected { connection.play(from: date) }
            }

            playbackRow
        }
        .padding(.vertical, Space.l)
        .padding(.horizontal, Space.m)
        .panel(padding: nil)
    }

    private static func windowLabel(_ window: TimeInterval) -> String {
        window >= 7 * 24 * 3600 ? "7D" : "\(Int(window / 3600))H"
    }

    @ViewBuilder
    private var playbackRow: some View {
        if connection.playback.isLive {
            HStack(spacing: Space.s) {
                if connection.phase != .connected && connection.segments.isEmpty {
                    Readout("Offline", caption: "Recordings load once connected")
                } else {
                    Readout(footageSummary, caption: connection.segments.isEmpty ? "Nothing recorded yet" : "Drag the strip to rewind")
                }
                Spacer(minLength: Space.s)
                exportTool
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s) {
                    pauseTool
                    speedPill
                    Spacer(minLength: Space.xs)
                    livePill
                    exportTool
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.s) {
                        pauseTool
                        Spacer(minLength: Space.xs)
                        livePill
                        exportTool
                    }
                    speedPill
                }
            }
        }
    }

    private var footageSummary: String {
        let cutoff = Date().addingTimeInterval(-window)
        let seconds = connection.segments.filter { $0.end > cutoff }.reduce(0.0) { total, segment in
            total + segment.end.timeIntervalSince(max(segment.start, cutoff))
        }
        guard seconds > 0 else { return "No footage" }
        let minutes = Int(seconds / 60)
        let text = minutes >= 60 ? "\(minutes / 60) H \(minutes % 60) M" : minutes > 0 ? "\(minutes) M" : "\(Int(seconds)) S"
        return "\(text) recorded"
    }

    private var pauseTool: some View {
        Button { connection.togglePause() } label: {
            Image(systemName: connection.playback.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.tool())
        .toolHover()
        .accessibilityLabel(connection.playback.isPlaying ? "Pause" : "Play")
    }

    private var speedPill: some View {
        SegmentPill([1.0, 2, 4, 8], selection: Binding(get: { connection.playback.rate },
                                                       set: { connection.setRate($0) })) { "\(Int($0))×" }
            .accessibilityLabel("Playback speed")
    }

    private var livePill: some View {
        Button { connection.goLive() } label: {
            Text("Live")
        }
        .buttonStyle(.pill(isOn: true))
        .accessibilityLabel("Back to live")
    }

    private var exportTool: some View {
        Button(action: onExport) { Image(systemName: "scissors") }
            .buttonStyle(.tool())
            .toolHover()
            .disabled(connection.segments.isEmpty)
            .opacity(connection.segments.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Export clip")
    }

    // MARK: Events

    private var eventsInWindow: [CameraEvent] {
        let cutoff = Date().addingTimeInterval(-window)
        return connection.events.filter { $0.date > cutoff }
    }

    private var filteredEvents: [CameraEvent] {
        eventsInWindow.filter { filter == nil || $0.kind == filter }.sorted { $0.date > $1.date }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            filterChips
            let events = filteredEvents
            if events.isEmpty && connection.phase != .connected && connection.segments.isEmpty {
                EmptyState(symbol: "wifi.slash", title: "Not connected",
                           message: "Recordings and events load once the camera connects.")
                    .frame(maxWidth: .infinity)
            } else if events.isEmpty {
                EmptyState(symbol: connection.segments.isEmpty ? "film.stack" : "checkmark.seal",
                           title: connection.segments.isEmpty ? "No recordings yet" : "All quiet",
                           message: connection.segments.isEmpty ? "Footage and events appear here once the camera starts recording."
                                                                : "Nothing detected in this period.")
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        Button {
                            guard connection.phase == .connected else { return }
                            selectedEvent = event.id
                            connection.play(from: event.date.addingTimeInterval(-5))
                        } label: {
                            EventRow(event: event, thumbnail: connection.thumbnail(for: event),
                                     isSelected: selectedEvent == event.id && !connection.playback.isLive)
                        }
                        .buttonStyle(.plain)
                        if index < events.count - 1 {
                            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, Space.l)
                        }
                    }
                }
                .panel(padding: nil)
            }
        }
    }

    private var filterChips: some View {
        let inWindow = eventsInWindow
        let kinds = Array(Set(inWindow.map(\.kind))).sorted { $0.title < $1.title }
        return ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                FilterChip(title: "All", count: inWindow.count, selected: filter == nil) { filter = nil }
                ForEach(kinds, id: \.self) { kind in
                    FilterChip(title: kind.title, symbol: kind.symbol, count: inWindow.filter { $0.kind == kind }.count,
                               selected: filter == kind) { filter = kind }
                }
            }
            .padding(Space.xs)
            .background(Palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .scrollIndicators(.hidden)
        .onChange(of: kinds) { _, kinds in
            if let filter, !kinds.contains(filter) { self.filter = nil }
        }
    }
}

/// One option in the event filter: a SegmentPill-style capsule with a count.
private struct FilterChip: View {
    let title: String
    var symbol: String?
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { action() }
        } label: {
            HStack(spacing: Space.xs) {
                if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
                Text(title).type(.readout, color: selected ? Palette.onAccent : Palette.textPrimary)
                Text("\(count)").type(.readout, color: selected ? Palette.onAccent.opacity(0.6) : Palette.textTertiary)
            }
            .foregroundStyle(selected ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 36)
            .background(selected ? Palette.accent : Palette.raisedHigh, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Event row

/// An event in a panel list: thumbnail, title, a kind LED and the time. Tap to replay.
struct EventRow: View {
    let event: CameraEvent
    let thumbnail: UIImage?
    var isSelected = false

    var body: some View {
        HStack(spacing: Space.m) {
            ZStack {
                Palette.raised
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: event.kind.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(event.kind.timelineTint)
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(.continuous(Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 2 : 1))

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(event.label).type(.headline).lineLimit(1)
                HStack(spacing: Space.s) {
                    LED(event.kind.timelineTint, label: event.kind.title)
                    Text(event.date.timelineStamp).type(.readout, color: Palette.textTertiary)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: isSelected ? "play.fill" : "play")
                .font(.footnote.weight(.bold))
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(isSelected ? Palette.accent : Palette.raised, in: Circle())
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the recording from just before this event")
    }
}

// MARK: - Timeline strip

/// The last `window` of time as an instrument: a column graph of recorded footage, LED marks for
/// events, a tick scale with clock labels, and a red needle at the playback position (or at the
/// right edge while live). Drag or tap to jump.
struct TimelineStrip: View {
    let segments: [RecordingSegment]
    let events: [CameraEvent]
    let window: TimeInterval
    let position: Date?
    let onSeek: (Date) -> Void
    @State private var dragDate: Date?

    // Vertical layout of the instrument.
    private let height: CGFloat = 96
    private let bubbleY: CGFloat = 8
    private let barTop: CGFloat = 28
    private let baseline: CGFloat = 58
    private let labelY: CGFloat = 84
    private let pitch: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            GeometryReader { geo in
                let end = context.date
                let start = end.addingTimeInterval(-window)
                let width = geo.size.width
                let x = { (date: Date) -> CGFloat in CGFloat(date.timeIntervalSince(start) / window) * width }
                let columns = Int(width / pitch)
                let coverage = Self.coverage(segments: segments, start: start, window: window, columns: columns)
                let marked = Self.eventColumns(events: events, start: start, end: end, columns: columns)
                let scale = Self.scale(for: window)
                let marks = Self.marks(start: start, end: end, every: scale.minor)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        // Footage columns: raised bars where something was recorded, dots where not.
                        // Columns holding an event stand taller, tinted by the most urgent kind.
                        for column in 0..<columns {
                            let cx = CGFloat(column) * pitch
                            if let kind = marked[column] {
                                context.fill(Path(roundedRect: CGRect(x: cx, y: barTop, width: 2, height: baseline - barTop - 3), cornerRadius: 1),
                                             with: .color(kind.timelineTint))
                            } else if coverage[column] {
                                context.fill(Path(roundedRect: CGRect(x: cx, y: barTop + 10, width: 2, height: baseline - barTop - 13), cornerRadius: 1),
                                             with: .color(Palette.textSecondary))
                            } else {
                                context.fill(Path(CGRect(x: cx, y: baseline - 4, width: 2, height: 2)), with: .color(Palette.textDisabled))
                            }
                        }
                        // LEDs above the strip, one per few columns so dense activity stays readable.
                        let bucket = 3
                        for first in stride(from: 0, to: columns, by: bucket) {
                            let kinds = (first..<min(columns, first + bucket)).compactMap { marked[$0] }
                            guard let kind = kinds.max(by: { $0.urgency < $1.urgency }) else { continue }
                            let tint = kind.timelineTint
                            let cx = CGFloat(first) * pitch + CGFloat(bucket) * pitch / 2 - 1
                            let dot = CGRect(x: cx - 2.5, y: barTop - 11, width: 5, height: 5)
                            context.drawLayer { layer in
                                layer.addFilter(.shadow(color: tint.opacity(0.8), radius: 3))
                                layer.fill(Path(ellipseIn: dot), with: .color(tint))
                            }
                        }
                        // Baseline and tick scale.
                        context.fill(Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)), with: .color(Palette.stroke))
                        for mark in marks {
                            let major = Self.isMajor(mark, every: scale.major)
                            let mx = x(mark)
                            context.fill(Path(CGRect(x: mx - 0.5, y: baseline + 3, width: 1, height: major ? 11 : 5)),
                                         with: .color(major ? Palette.textSecondary : Palette.textTertiary))
                        }
                    }

                    // Clock labels under the major ticks.
                    ForEach(marks.filter { Self.isMajor($0, every: scale.major) }, id: \.self) { mark in
                        let mx = x(mark)
                        if mx > 16, mx < width - 16 {
                            Text(Self.label(mark, window: window))
                                .type(.readout, color: Palette.textTertiary)
                                .fixedSize()
                                .position(x: mx, y: labelY)
                        }
                    }

                    needle(at: dragDate ?? position, x: x, width: width)
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / width))
                        dragDate = start.addingTimeInterval(window * fraction)
                    }
                    .onEnded { _ in
                        if let dragDate { onSeek(dragDate) }
                        dragDate = nil
                    })
            }
        }
        .frame(height: height)
        .sensoryFeedback(.selection, trigger: dragDate == nil)
        .accessibilityElement()
        .accessibilityLabel("Recording timeline")
        .accessibilityValue(position.map { "Playing from \($0.formatted(date: .omitted, time: .shortened))" } ?? "Live")
        .accessibilityHint("Swipe up or down to move through the recording")
        .accessibilityAdjustableAction { direction in
            let current = position ?? Date()
            let step = window / 24
            switch direction {
            case .increment: onSeek(min(Date(), current.addingTimeInterval(step)))
            case .decrement: onSeek(current.addingTimeInterval(-step))
            @unknown default: break
            }
        }
    }

    /// The red needle with its time bubble. At the right edge, labelled LIVE, when nothing is playing back.
    @ViewBuilder
    private func needle(at date: Date?, x: (Date) -> CGFloat, width: CGFloat) -> some View {
        let nx = date.map { min(width - 1, max(1, x($0))) } ?? (width - 1)
        let text = date.map(\.timelineClock) ?? "Live"
        Rectangle()
            .fill(Palette.live)
            .frame(width: 2, height: labelY - bubbleY - 14)
            .shadow(color: Palette.live.opacity(0.6), radius: 3)
            .position(x: nx, y: (bubbleY + labelY - 14) / 2 + 6)
        Text(text)
            .type(.readout, color: Palette.textPrimary)
            .padding(.horizontal, Space.xs + Space.xxs)
            .padding(.vertical, Space.xxs)
            .background(Palette.live, in: .continuous(Radius.badge))
            .fixedSize()
            .modifier(ClampedPosition(x: nx, y: bubbleY, width: width))
    }

    // MARK: Geometry helpers

    /// Which `pitch`-wide columns contain recorded footage. Linear sweep over sorted segments.
    static func coverage(segments: [RecordingSegment], start: Date, window: TimeInterval, columns: Int) -> [Bool] {
        guard columns > 0 else { return [] }
        var result = Array(repeating: false, count: columns)
        let span = window / Double(columns)
        for segment in segments where segment.end > start {
            let first = max(0, Int(segment.start.timeIntervalSince(start) / span))
            let last = min(columns - 1, Int(segment.end.timeIntervalSince(start) / span))
            guard first <= last else { continue }
            for column in first...last { result[column] = true }
        }
        return result
    }

    /// The most urgent event kind in each column, if any.
    static func eventColumns(events: [CameraEvent], start: Date, end: Date, columns: Int) -> [Int: EventKind] {
        guard columns > 0 else { return [:] }
        let span = end.timeIntervalSince(start) / Double(columns)
        var result: [Int: EventKind] = [:]
        for event in events where event.date > start && event.date <= end {
            let column = min(columns - 1, Int(event.date.timeIntervalSince(start) / span))
            if let existing = result[column], existing.urgency >= event.kind.urgency { continue }
            result[column] = event.kind
        }
        return result
    }

    static func scale(for window: TimeInterval) -> (major: TimeInterval, minor: TimeInterval) {
        switch window {
        case ...3600: (600, 120)
        case ...(6 * 3600): (3600, 900)
        case ...(24 * 3600): (4 * 3600, 3600)
        default: (24 * 3600, 6 * 3600)
        }
    }

    /// Tick dates aligned to round clock times.
    static func marks(start: Date, end: Date, every interval: TimeInterval) -> [Date] {
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: start))
        let first = (((start.timeIntervalSince1970 + offset) / interval).rounded(.up) * interval) - offset
        return stride(from: first, through: end.timeIntervalSince1970, by: interval).map { Date(timeIntervalSince1970: $0) }
    }

    static func isMajor(_ date: Date, every interval: TimeInterval) -> Bool {
        let local = date.timeIntervalSince1970 + TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        return abs(local.truncatingRemainder(dividingBy: interval)) < 1
    }

    static func label(_ date: Date, window: TimeInterval) -> String {
        window > 24 * 3600 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.timelineClockShort
    }
}

/// Places a view centred on `x` but keeps it inside 0...width.
private struct ClampedPosition: ViewModifier {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(x: min(width - size.width / 2, max(size.width / 2, x)), y: y)
    }
}

// MARK: - Readout helpers

extension Date {
    /// "22:06:56": 24-hour clock for instrument readouts.
    var timelineClock: String {
        formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                            timeZone: .current, calendar: .current))
    }

    /// "22:06".
    var timelineClockShort: String {
        formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                            timeZone: .current, calendar: .current))
    }

    /// Time only for today ("22:06:56"), otherwise "OCT 5 22:06".
    var timelineStamp: String {
        Calendar.current.isDateInToday(self) ? timelineClock
            : "\(formatted(.dateTime.month(.abbreviated).day())) \(timelineClockShort)"
    }
}

extension EventKind {
    /// Which kind wins when several share a mark on the strip.
    var urgency: Int {
        switch self {
        case .glassBreak, .alarm, .crying, .overheating: 3
        case .lowBattery: 2
        case .person, .animal, .sound, .barking: 1
        case .motion: 0
        }
    }

    /// LED / tick colour: urgent kinds are red, things seen are accent, things heard are info.
    var timelineTint: Color {
        switch self {
        case .glassBreak, .alarm, .crying, .overheating: Palette.live
        case .lowBattery: Palette.warn
        case .sound, .barking: Palette.info
        case .motion, .person, .animal: Palette.accent
        }
    }
}
