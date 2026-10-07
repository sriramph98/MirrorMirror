import SwiftUI
import MirrorUI

/// Side panel over the full-screen picture: the last 24 hours as a tick ruler driven by the
/// remote (left/right = 30 s, quick swipes accelerate, Select plays from there) and the list of
/// events (Select replays from five seconds before). Menu closes it.
struct TimelinePanelTV: View {
    enum Tab: Hashable, CaseIterable { case timeline, events }

    @ObservedObject var connection: CameraConnection
    let tab: Tab
    var focus: FocusState<FullScreenView.Focus?>.Binding
    let onClose: () -> Void

    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Tab
    @State private var windowEnd = Date()
    @State private var value: Double = TimelinePanelTV.window
    @State private var selectedEvent: UUID?
    @FocusState private var inner: Item?

    enum Item: Hashable { case tab(Tab), ruler, play, live, event(UUID) }

    static let window: Double = 24 * 3600
    static let step: Double = 30

    init(connection: CameraConnection, tab: Tab, focus: FocusState<FullScreenView.Focus?>.Binding, onClose: @escaping () -> Void) {
        self.connection = connection
        self.tab = tab
        self.focus = focus
        self.onClose = onClose
        _selected = State(initialValue: tab)
    }

    /// Ticks land on whole and half minutes when the window ends on one.
    private static func snappedNow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / step).rounded(.up) * step)
    }

    private func tickKind(_ v: Double) -> TVTickRuler.TickKind {
        let parts = Calendar.current.dateComponents([.minute, .second], from: date(v))
        guard parts.second == 0, let minute = parts.minute else { return .minor }
        return minute % 15 == 0 ? .major : minute % 5 == 0 ? .medium : .minor
    }

    private var selectedDate: Date { windowEnd.addingTimeInterval(value - Self.window) }
    private func date(_ v: Double) -> Date { windowEnd.addingTimeInterval(v - Self.window) }
    private func position(_ date: Date) -> Double { Self.window + date.timeIntervalSince(windowEnd) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            switch selected {
            case .timeline: timeline
            case .events: events
            }
        }
        .padding(Space.xxl)
        .frame(width: TVSize.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.surface.opacity(0.96), in: .continuous(Radius.deck))
        .overlay(RoundedRectangle(cornerRadius: Radius.deck, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .padding(.vertical, Space.xxxl)
        .padding(.trailing, TVSize.margin - Space.l)
        .focusSection()
        .onAppear {
            windowEnd = Self.snappedNow()
            value = position(connection.playback.isLive ? Date() : (connection.playback.date ?? Date()))
            connection.refreshTimeline()
            inner = selected == .timeline ? .ruler : (connection.events.last.map { .event($0.id) } ?? .tab(.events))
        }
        .onChange(of: connection.playback.date) { _, date in
            // Follow playback unless the viewer is scrubbing.
            guard let date, inner != .ruler else { return }
            value = min(Self.window, max(0, position(date)))
        }
        .onChange(of: tab) { _, tab in selected = tab }
        .onChange(of: selected) { _, tab in
            inner = tab == .timeline ? .ruler : (connection.events.last.map { .event($0.id) } ?? .tab(.events))
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if connection.phase == .connected { connection.refreshTimeline() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.l) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { withAnimation(reduceMotion ? nil : Motion.snappy) { selected = tab } } label: {
                    Text(tab == .timeline ? "Timeline" : "Events")
                }
                .buttonStyle(.tvPill(isOn: selected == tab))
                .focused($inner, equals: .tab(tab))
            }
            Spacer(minLength: 0)
            Text(connection.camera.name).tv(.caps).lineLimit(1)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // The big readout: the selected moment.
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(selectedDate.tvClockShort).tv(.numeral)
                Text(selectedDate.formatted(.verbatim("\(second: .twoDigits)", timeZone: .current, calendar: .current)))
                    .tv(.title, color: Palette.textSecondary)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Text(selectedDate.tvDayLabel).tv(.caps, color: Palette.textPrimary)
                    Text(agoLabel).tv(.readout, color: Palette.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)

            TVTickRuler(value: $value, range: 0...Self.window, step: Self.step, labelEvery: 900, spacing: 7,
                        format: { date($0).tvClockShort },
                        tickKind: tickKind,
                        coverage: connection.segments.map { position($0.start)...position($0.end) },
                        marks: connection.events.map { (position($0.date), $0.kind.tvTint) },
                        onSelect: playFromRuler,
                        onMoveUp: { inner = .tab(.timeline) },
                        onMoveDown: { inner = .play })
                .padding(.horizontal, Space.s)

            HStack(spacing: Space.l) {
                Button(action: playFromRuler) { Label("Play from here", systemImage: "play.fill") }
                    .buttonStyle(.tvPill(isOn: !connection.playback.isLive && isAtPlayback))
                    .focused($inner, equals: .play)
                    .disabled(connection.phase != .connected)
                Button {
                    connection.goLive()
                    windowEnd = Self.snappedNow()
                    value = Self.window
                } label: {
                    HStack(spacing: Space.s) {
                        Circle().fill(Palette.live).frame(width: Space.m, height: Space.m)
                        Text("Live")
                    }
                }
                .buttonStyle(.tvPill(isOn: connection.playback.isLive))
                .focused($inner, equals: .live)
            }
            .labelStyle(TVBarLabelStyle())

            Text(connection.segments.isEmpty
                 ? "No recordings in the last 24 hours. Footage appears here once the camera has recorded something."
                 : "Swipe left or right to move in 30-second steps; keep swiping to go faster. The bar shows recorded footage, dots are events.")
                .tv(.footnote, color: Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var isAtPlayback: Bool {
        guard let date = connection.playback.date else { return false }
        return abs(date.timeIntervalSince(selectedDate)) < Self.step
    }

    private var agoLabel: String {
        let ago = max(0, Date().timeIntervalSince(selectedDate))
        if ago < 90 { return "Just now" }
        if ago < 3600 { return "\(Int(ago / 60)) min ago" }
        let hours = Int(ago / 3600), minutes = Int(ago.truncatingRemainder(dividingBy: 3600) / 60)
        return minutes == 0 ? "\(hours) h ago" : "\(hours) h \(minutes) min ago"
    }

    private func playFromRuler() {
        guard connection.phase == .connected else { return }
        if value >= Self.window - Self.step {
            connection.goLive()
        } else {
            connection.play(from: selectedDate)
        }
    }

    // MARK: Events

    @ViewBuilder
    private var events: some View {
        let list = connection.events.sorted { $0.date > $1.date }
        if list.isEmpty {
            VStack(spacing: Space.l) {
                Image(systemName: "bell.slash").font(.system(size: 56, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                Text("No events yet").tv(.title)
                Text("Motion and sound the camera notices show up here, newest first.")
                    .tv(.callout, color: Palette.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Space.xxl)
        } else {
            ScrollView {
                LazyVStack(spacing: Space.s) {
                    ForEach(list) { event in
                        Button {
                            selectedEvent = event.id
                            connection.play(from: event.date.addingTimeInterval(-5))
                        } label: {
                            TVEventRow(event: event, thumbnail: connection.thumbnail(for: event), isSelected: selectedEvent == event.id)
                        }
                        .buttonStyle(.tvRow(isSelected: selectedEvent == event.id))
                        .focused($inner, equals: .event(event.id))
                        .disabled(connection.phase != .connected)
                    }
                }
                .padding(.vertical, Space.s)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}

/// One event: thumbnail (or the kind's glyph), label, kind LED and time.
struct TVEventRow: View {
    let event: CameraEvent
    let thumbnail: UIImage?
    var isSelected = false

    var body: some View {
        HStack(spacing: Space.l) {
            ZStack {
                Palette.raised
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: event.kind.symbol).font(.system(size: 32, weight: .semibold)).foregroundStyle(event.kind.tvTint)
                }
            }
            .frame(width: TVSize.thumbnail.width, height: TVSize.thumbnail.height)
            .clipShape(.continuous(Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 3 : 1))

            VStack(alignment: .leading, spacing: Space.s) {
                Text(event.label).tv(.headline).lineLimit(1)
                HStack(spacing: Space.m) {
                    TVLED(event.kind.tvTint, label: event.kind.title)
                    Text(event.date.tvStamp).tv(.readout, color: Palette.textTertiary)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: isSelected ? "play.fill" : "play")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.textSecondary)
                .frame(width: 52, height: 52)
                .background(isSelected ? Palette.accent : Palette.raised, in: Circle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the recording from five seconds before this")
    }
}
