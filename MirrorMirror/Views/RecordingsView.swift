import SwiftUI
import MirrorUI
import AVKit
import Photos

/// Footage recorded by this device while it was a camera: browse by day, play, trim, export.
/// Pushed on iPhone (with a back button), the detail column on iPad.
struct RecordingsView: View {
    @ObservedObject private var store = RecordingStore.shared
    /// Nil when embedded (iPad detail): no back button.
    var onClose: (() -> Void)? = nil

    @State private var selected: RecordingSegment?
    @State private var confirmDeleteAll = false
    @State private var onlyEvents = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Recordings", leadingSymbol: "chevron.left", leadingAction: onClose)
            if store.segments.isEmpty {
                Spacer(minLength: 0)
                EmptyState(symbol: "film.stack", title: "No recordings",
                           message: "Footage this device records in camera mode appears here. It never leaves the device unless you export it.")
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            } else {
                list
            }
        }
        .canvasBackground()
        .confirmationDialog("Delete all recordings on this device?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
        } message: {
            Text("\(store.segments.count) clips, \(store.totalBytes.byteString). This can't be undone.")
        }
        .onAppear {
            if ScreenHook.screen == "player", selected == nil {
                selected = store.segments.first { s in store.events.contains { s.contains($0.date) } } ?? store.segments.last
            }
        }
        .sheet(item: $selected) { segment in
            RecordingPlayer(segment: segment).mirrorSheet()
        }
    }

    // MARK: List

    private var list: some View {
        List {
            summary
                .plainRow(insets: EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))

            ToggleRow("Only clips with events", symbol: "bolt.fill", isOn: $onlyEvents.animation(Motion.smooth))
                .groupedRow(position: .single)

            if visibleSegments.isEmpty {
                Text("No clips with events.")
                    .type(.footnote, color: Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .plainRow(insets: EdgeInsets(top: Space.xl, leading: Space.l, bottom: Space.xl, trailing: Space.l))
            }

            ForEach(days, id: \.self) { day in
                let segments = segments(on: day)
                HStack {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).type(.caps)
                    Spacer()
                    ReadoutLine(["\(segments.count) clips", segments.map(\.byteSize).reduce(0, +).byteString],
                                color: Palette.textTertiary)
                }
                .plainRow(insets: EdgeInsets(top: Space.xl, leading: Space.l + Space.xs, bottom: Space.s, trailing: Space.l + Space.xs))

                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Button { selected = segment } label: {
                        SegmentRow(segment: segment, events: events(in: segment))
                    }
                    .buttonStyle(.plain)
                    .groupedRow(position: .init(index: index, count: segments.count))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.delete(segment) } label: { Label("Delete", systemImage: "trash") }
                    }
                    // Right-click on the Mac, long press elsewhere: the same delete as the swipe.
                    .contextMenu {
                        Button(role: .destructive) { store.delete(segment) } label: { Label("Delete Clip", systemImage: "trash") }
                    }
                }
            }

            Color.clear.frame(height: Space.l).plainRow(insets: EdgeInsets())
            Button { confirmDeleteAll = true } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: "trash").font(.body.weight(.semibold)).frame(width: Space.xl)
                    Text("Delete all recordings").type(.body, color: Palette.live)
                    Spacer()
                }
                .foregroundStyle(Palette.live)
                .padding(.horizontal, Space.l)
                .frame(minHeight: ControlSize.toolLarge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .groupedRow(position: .single)
            Color.clear.frame(height: Space.xxl).plainRow(insets: EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .readableWidth()
    }

    private var summary: some View {
        HStack(alignment: .bottom, spacing: Space.l) {
            let size = Self.splitBytes(store.totalBytes)
            Numeral(size.value, unit: size.unit, caption: "On this device")
            Spacer(minLength: Space.s)
            VStack(alignment: .trailing, spacing: Space.s) {
                StatChip("\(store.segments.count)", tag: "Clips")
                StatChip("\(store.events.count)", tag: "Events", tint: store.events.isEmpty ? Palette.textPrimary : Palette.accent)
            }
        }
        .panel()
    }

    /// "1.2 GB" → ("1.2", "GB") for a numeral with a small unit.
    private static func splitBytes(_ bytes: Int64) -> (value: String, unit: String) {
        let parts = bytes.byteString.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (bytes.byteString, "")
    }

    private var visibleSegments: [RecordingSegment] {
        onlyEvents ? store.segments.filter { !events(in: $0).isEmpty } : store.segments
    }

    private var days: [Date] {
        Array(Set(visibleSegments.map { Calendar.current.startOfDay(for: $0.start) })).sorted(by: >)
    }

    private func segments(on day: Date) -> [RecordingSegment] {
        visibleSegments.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.reversed()
    }

    private func events(in segment: RecordingSegment) -> [CameraEvent] {
        store.events.filter { segment.contains($0.date) }
    }
}

// MARK: - Row

private struct SegmentRow: View {
    let segment: RecordingSegment
    let events: [CameraEvent]

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("\(segment.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute().second())) – \(segment.end.formatted(.dateTime.hour().minute().second()))")
                    .type(.readoutLarge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ReadoutLine([Self.duration(segment.duration), "\(segment.height)p", segment.byteSize.byteString])
            }
            Spacer(minLength: Space.s)
            if !kinds.isEmpty {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    ForEach(kinds.prefix(2), id: \.self) { kind in
                        LED(kind.ledColor, label: kind.title)
                    }
                    if kinds.count > 2 {
                        Text("+\(kinds.count - 2)").type(.readout, color: Palette.textTertiary)
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: ControlSize.toolLarge + Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the clip")
    }

    /// Event kinds in the order they happened, without repeats.
    private var kinds: [EventKind] {
        var seen = Set<EventKind>()
        return events.sorted { $0.date < $1.date }.map(\.kind).filter { seen.insert($0).inserted }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total) s"
    }
}

// MARK: - Panel rows inside a List

/// Where a row sits in its panel, so only the outer corners are rounded.
private struct RowPosition {
    let first: Bool
    let last: Bool

    static let single = RowPosition(first: true, last: true)

    init(first: Bool, last: Bool) {
        self.first = first
        self.last = last
    }

    init(index: Int, count: Int) {
        first = index == 0
        last = index == count - 1
    }
}

private extension View {
    /// A list row with no chrome.
    func plainRow(insets: EdgeInsets) -> some View {
        self
            .listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A list row drawn as part of a `.panel()`: surface fill, panel radius on the outer
    /// corners, hairlines between rows. Keeps List's swipe actions.
    func groupedRow(position: RowPosition) -> some View {
        let top = position.first ? Radius.panel : 0
        let bottom = position.last ? Radius.panel : 0
        return self
            .overlay(alignment: .bottom) {
                if !position.last {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, Space.l)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(
                UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                       bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
                    .fill(Palette.surface)
                    .padding(.horizontal, Space.l)
            )
            .padding(.horizontal, Space.l)
    }
}

// MARK: - Player

/// Plays one segment and exports a trimmed clip (which can extend into neighbouring segments).
private struct RecordingPlayer: View {
    let segment: RecordingSegment
    @ObservedObject private var store = RecordingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var exported: URL?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(segment.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                        leadingAction: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Viewfinder {
                        VideoPlayer(player: player)
                    } topLeading: {
                        Badge("Playback", style: .accent)
                    } topTrailing: {
                        ReadoutLine(["\(segment.height)p", SegmentRow.duration(segment.duration)], color: Palette.textPrimary)
                    }
                    .aspectRatio(CGFloat(segment.width) / CGFloat(max(1, segment.height)), contentMode: .fit)

                    SettingsSection("Trim", symbol: "scissors", footer: "Drag the dials. Times are from the start of this recording.") {
                        RulerRow("Start", value: $trimStart, in: 0...max(rulerStep, segment.duration), step: rulerStep, labelEvery: 10, format: clock)
                        RulerRow("End", value: $trimEnd, in: 0...max(rulerStep, segment.duration), step: rulerStep, labelEvery: 10, format: clock)
                        ValueRow("Clip length", value: clipLength,
                                 valueColor: trimEnd > trimStart ? Palette.textPrimary : Palette.live)
                    }

                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Events").type(.caps).padding(.horizontal, Space.xs)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.s) {
                                    ForEach(events) { event in
                                        Button { seek(event.date.timeIntervalSince(segment.start)) } label: {
                                            StatChip(event.date.formatted(.dateTime.hour().minute().second()),
                                                     symbol: event.kind.symbol, tint: event.kind.ledColor)
                                                .frame(minHeight: ControlSize.tool)
                                        }
                                        .buttonStyle(CardPressStyle())
                                        .accessibilityLabel("\(event.kind.title) at \(event.date.formatted(date: .omitted, time: .standard))")
                                    }
                                }
                            }
                        }
                    }

                    exportControls

                    if let message {
                        Text(message).type(.footnote, color: Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
        }
        .canvasBackground()
        .onAppear { trimEnd = segment.duration }
        .task {
            // After the trim handles settle, so their change handlers don't seek the new player.
            await Task.yield()
            let player = AVPlayer(url: store.url(for: segment))
            self.player = player
            player.play()
        }
        .onChange(of: trimStart) { _, value in
            if trimEnd < value { trimEnd = value }
            seek(value)
        }
        .onChange(of: trimEnd) { _, value in
            if trimStart > value { trimStart = value }
            seek(value)
        }
        .onDisappear {
            player?.pause()
            if let exported { try? FileManager.default.removeItem(at: exported) }
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        if exporting {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Exporting").type(.caps)
                    Spacer()
                    Text("\(Int(progress * 100))%").type(.readoutLarge, color: Palette.accent)
                }
                ProgressView(value: progress).tint(Palette.accent)
            }
            .panel()
        } else if let exported {
            VStack(spacing: Space.s) {
                ShareLink(item: exported) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.primary)
                Button { saveToPhotos(exported) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.secondary)
                    .macSaveAs(exported, suggestedName: "Mira \(segment.start.formatted(.dateTime.year().month().day().hour().minute()))")
            }
        } else {
            Button { export() } label: { Label("Export clip", systemImage: "scissors") }
                .buttonStyle(.primary)
                .disabled(trimEnd <= trimStart)
                .opacity(trimEnd <= trimStart ? 0.4 : 1)
        }
    }

    private var events: [CameraEvent] { store.events.filter { segment.contains($0.date) } }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var clipLength: String {
        let length = max(0, trimEnd - trimStart)
        return rulerStep < 1 ? String(format: "%.1f s", length) : SegmentRow.duration(length)
    }

    /// Tenths of a second for short clips so the dial has room to move; whole seconds otherwise.
    private var rulerStep: Double { segment.duration <= 15 ? 0.1 : 1 }

    /// Position inside the clip: "0:42", or "0:01.8" on short clips.
    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let base = String(format: "%d:%02d", whole / 60, whole % 60)
        guard rulerStep < 1 else { return base }
        return base + "." + String(Int((seconds * 10).rounded()) % 10)
    }

    private func export() {
        exporting = true
        message = nil
        Task {
            do {
                exported = try await ClipExporter.export(from: segment.start.addingTimeInterval(trimStart),
                                                         to: segment.start.addingTimeInterval(trimEnd),
                                                         store: store, quality: .original) { value in
                    Task { @MainActor in progress = value }
                }
            } catch {
                message = error.localizedDescription
            }
            exporting = false
        }
    }

    private func saveToPhotos(_ url: URL) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                message = "Allow Photos access in Settings to save clips."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
                message = "Saved to Photos."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
