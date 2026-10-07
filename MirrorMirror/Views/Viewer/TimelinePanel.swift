import SwiftUI

/// Under the live video: playback controls, a scrubbable strip of recorded footage with
/// event markers, and the event list.
struct TimelinePanel: View {
    @ObservedObject var connection: CameraConnection
    let onExport: () -> Void
    @State private var window: TimeInterval = 3600
    @State private var filter: EventKind?

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            TimelineStrip(segments: connection.segments, events: connection.events, window: window,
                          position: connection.playback.isLive ? nil : connection.playback.date) { date in
                connection.play(from: date)
            }
            .frame(height: 56)
            .padding(.horizontal, 16)

            Picker("Window", selection: $window) {
                Text("1 h").tag(TimeInterval(3600))
                Text("6 h").tag(TimeInterval(6 * 3600))
                Text("24 h").tag(TimeInterval(24 * 3600))
                Text("7 d").tag(TimeInterval(7 * 24 * 3600))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            eventList
        }
        .background(Color.black)
        .onAppear { connection.refreshTimeline() }
        .onChange(of: connection.phase) { _, phase in if phase == .connected { connection.refreshTimeline() } }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if connection.playback.isLive {
                Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    connection.play(from: Date().addingTimeInterval(-60))
                } label: {
                    Label("Back 1 min", systemImage: "gobackward.60")
                }
                .buttonStyle(.bordered)
                .disabled(connection.segments.isEmpty)
            } else {
                Button { connection.togglePause() } label: {
                    Image(systemName: connection.playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                }
                .buttonStyle(.bordered)
                Menu {
                    ForEach([1.0, 2, 4, 8], id: \.self) { rate in
                        Button("\(Int(rate))×") { connection.setRate(rate) }
                    }
                } label: {
                    Text("\(Int(connection.playback.rate))×").frame(width: 28)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button { connection.goLive() } label: {
                    Label("Live", systemImage: "forward.end.fill")
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            }
            Button(action: onExport) { Image(systemName: "scissors") }
                .buttonStyle(.bordered)
                .disabled(connection.segments.isEmpty)
                .accessibilityLabel("Export clip")
        }
    }

    private var filteredEvents: [CameraEvent] {
        let cutoff = Date().addingTimeInterval(-window)
        return connection.events
            .filter { $0.date > cutoff && (filter == nil || $0.kind == filter) }
            .reversed()
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    FilterChip(title: "All", selected: filter == nil) { filter = nil }
                    ForEach(Array(Set(connection.events.map(\.kind))).sorted { $0.title < $1.title }, id: \.self) { kind in
                        FilterChip(title: kind.title, symbol: kind.symbol, selected: filter == kind) { filter = kind }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if filteredEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(.secondary)
                    Text(connection.segments.isEmpty ? "No recordings yet." : "Nothing detected in this period.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEvents) { event in
                    Button { connection.play(from: event.date.addingTimeInterval(-5)) } label: {
                        EventRow(event: event, thumbnail: connection.thumbnail(for: event))
                    }
                    .listRowBackground(Color.black)
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EventRow: View {
    let event: CameraEvent
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: event.kind.symbol).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.label).font(.subheadline.weight(.medium))
                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
    }
}

/// Horizontal bar of the last `window` seconds: grey where there's footage, ticks for events.
/// Drag or tap to jump.
struct TimelineStrip: View {
    let segments: [RecordingSegment]
    let events: [CameraEvent]
    let window: TimeInterval
    let position: Date?
    let onSeek: (Date) -> Void
    @State private var dragDate: Date?

    var body: some View {
        GeometryReader { geo in
            let end = Date()
            let start = end.addingTimeInterval(-window)
            let x = { (date: Date) -> CGFloat in
                CGFloat(date.timeIntervalSince(start) / window) * geo.size.width
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
                ForEach(segments.filter { $0.end > start }) { segment in
                    let left = max(0, x(segment.start)), right = min(geo.size.width, x(segment.end))
                    Rectangle().fill(Color.white.opacity(0.28))
                        .frame(width: max(1, right - left), height: 24)
                        .offset(x: left)
                }
                ForEach(events.filter { $0.date > start }) { event in
                    Capsule().fill(Theme.accent).frame(width: 3, height: 40).offset(x: x(event.date) - 1.5)
                }
                if let marker = dragDate ?? position {
                    Rectangle().fill(.white).frame(width: 2, height: 56).offset(x: x(marker) - 1)
                    Text(marker.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .background(.black, in: Capsule())
                        .offset(x: min(max(0, x(marker) - 24), geo.size.width - 52), y: -24)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = min(1, max(0, value.location.x / geo.size.width))
                    dragDate = start.addingTimeInterval(window * fraction)
                }
                .onEnded { _ in
                    if let dragDate { onSeek(dragDate) }
                    dragDate = nil
                })
        }
        .accessibilityLabel("Recording timeline")
    }
}
