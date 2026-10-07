import SwiftUI
import AVKit
import Photos

/// Footage recorded by this device while it was a camera: browse by day, play, trim, export.
struct RecordingsView: View {
    @ObservedObject private var store = RecordingStore.shared
    @State private var selected: RecordingSegment?
    @State private var confirmDeleteAll = false
    @State private var showEvents = false

    var body: some View {
        List {
            if store.segments.isEmpty {
                ContentUnavailableView("No recordings", systemImage: "film",
                                       description: Text("Start camera mode on this device to record."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    LabeledContent("Storage used", value: store.totalBytes.byteString)
                    Toggle("Only clips with events", isOn: $showEvents)
                }
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(segments(on: day).reversed()) { segment in
                            Button { selected = segment } label: { row(segment) }
                                .swipeActions { Button("Delete", role: .destructive) { store.delete(segment) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .toolbar {
            if !store.segments.isEmpty {
                Button("Delete All", role: .destructive) { confirmDeleteAll = true }
            }
        }
        .confirmationDialog("Delete all recordings on this device?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
        }
        .sheet(item: $selected) { segment in
            RecordingPlayer(segment: segment)
        }
    }

    private var visibleSegments: [RecordingSegment] {
        showEvents ? store.segments.filter { !events(in: $0).isEmpty } : store.segments
    }

    private var days: [Date] {
        Array(Set(visibleSegments.map { Calendar.current.startOfDay(for: $0.start) })).sorted(by: >)
    }

    private func segments(on day: Date) -> [RecordingSegment] {
        visibleSegments.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    private func events(in segment: RecordingSegment) -> [CameraEvent] {
        store.events.filter { segment.contains($0.date) }
    }

    private func row(_ segment: RecordingSegment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(segment.start.formatted(date: .omitted, time: .standard)) – \(segment.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.medium))
                Text("\(Int(segment.duration)) s · \(segment.height)p · \(segment.byteSize.byteString)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(Set(events(in: segment).map(\.kind))), id: \.self) { kind in
                    Image(systemName: kind.symbol).font(.caption).foregroundStyle(Theme.accent)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

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
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(CGFloat(segment.width) / CGFloat(max(1, segment.height)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Trim").font(.headline)
                    HStack {
                        Text("Start").frame(width: 44, alignment: .leading)
                        Slider(value: $trimStart, in: 0...segment.duration) { editing in if !editing { seek(trimStart) } }
                        Text(time(trimStart)).monospacedDigit().font(.caption).fixedSize().frame(minWidth: 72, alignment: .trailing)
                    }
                    HStack {
                        Text("End").frame(width: 44, alignment: .leading)
                        Slider(value: $trimEnd, in: 0...segment.duration) { editing in if !editing { seek(trimEnd) } }
                        Text(time(trimEnd)).monospacedDigit().font(.caption).fixedSize().frame(minWidth: 72, alignment: .trailing)
                    }
                }
                .font(.subheadline)

                if !events.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(events) { event in
                                Button {
                                    seek(event.date.timeIntervalSince(segment.start))
                                } label: {
                                    Label(event.date.formatted(date: .omitted, time: .standard), systemImage: event.kind.symbol)
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if exporting {
                    ProgressView(value: progress) { Text("Exporting…") }
                } else if let exported {
                    HStack {
                        ShareLink(item: exported) { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                        Button { saveToPhotos(exported) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Button { export() } label: {
                        Label("Export Clip", systemImage: "scissors").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .disabled(trimEnd <= trimStart)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding()
            .navigationTitle(segment.start.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            trimEnd = segment.duration
            let player = AVPlayer(url: store.url(for: segment))
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            if let exported { try? FileManager.default.removeItem(at: exported) }
        }
    }

    private var events: [CameraEvent] { store.events.filter { segment.contains($0.date) } }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func time(_ seconds: Double) -> String {
        segment.start.addingTimeInterval(seconds).formatted(.dateTime.hour().minute().second())
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
