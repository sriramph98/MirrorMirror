import SwiftUI
import AVFoundation
import Photos
import MirrorUI

/// Pick a range of the camera's recordings, have the camera cut it, and receive the clip.
struct ExportSheet: View {
    @ObservedObject var connection: CameraConnection
    @Environment(\.dismiss) private var dismiss
    @State private var end = Date()
    @State private var duration: TimeInterval = 30
    @State private var quality: ExportQuality = .hd720
    @State private var jobID: UUID?
    @State private var saved = false
    @State private var clipDuration: Double?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Export clip", leadingAction: close)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let jobID, let job = connection.exports[jobID] {
                        progress(job)
                    } else {
                        form
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
        }
        .canvasBackground()
        .preferredColorScheme(.dark)
        .onAppear {
            // Default: the 30 s around what's on screen.
            if let date = connection.playback.date, !connection.playback.isLive {
                end = min(Date(), date.addingTimeInterval(15))
            } else {
                end = Date().addingTimeInterval(-60)
            }
        }
    }

    private func close() {
        if let jobID { connection.dismissExport(jobID) }
        dismiss()
    }

    private var start: Date { end.addingTimeInterval(-duration) }

    // MARK: Form

    @ViewBuilder
    private var form: some View {
        // End time: the hero readout, nudged in 10 s steps.
        VStack(spacing: Space.l) {
            HStack {
                Text("Clip ends").type(.caps)
                Spacer()
                DatePicker("Ends at", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .tint(Palette.accent)
            }
            HStack(spacing: Space.m) {
                Button { end = end.addingTimeInterval(-10) } label: { Text("−10 s").type(.readout, color: Palette.textPrimary) }
                    .buttonStyle(.tool(size: ControlSize.toolLarge))
                    .accessibilityLabel("10 seconds earlier")
                Spacer(minLength: 0)
                VStack(spacing: Space.xs) {
                    Text(end.timelineClock).type(.numeral).lineLimit(1).minimumScaleFactor(0.6)
                    ReadoutLine([start.timelineClock + " → " + end.timelineClock, lengthLabel(duration)], color: Palette.textTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Clip")
                .accessibilityValue("\(start.formatted(date: .omitted, time: .standard)) to \(end.formatted(date: .omitted, time: .standard))")
                Spacer(minLength: 0)
                Button { end = min(Date(), end.addingTimeInterval(10)) } label: { Text("+10 s").type(.readout, color: Palette.textPrimary) }
                    .buttonStyle(.tool(size: ControlSize.toolLarge))
                    .accessibilityLabel("10 seconds later")
            }
        }
        .panel()

        SettingsSection("Clip", footer: "Footage from the last minute may still be recording; pick a slightly earlier end if the clip comes up short.") {
            SettingRow("Length") {
                SegmentPill([10.0, 30, 60, 120, 300], selection: $duration, label: lengthLabel)
            }
            SettingRow("Quality") {
                SegmentPill(ExportQuality.allCases, selection: $quality, label: \.shortLabel)
            }
        }

        VStack(spacing: Space.m) {
            Button("Export clip") {
                jobID = connection.exportClip(from: start, to: end, quality: quality)
            }
            .buttonStyle(.primary)
            .disabled(connection.phase != .connected)
            .opacity(connection.phase == .connected ? 1 : 0.4)
            Text(connection.phase == .connected
                 ? "The camera trims the clip and sends it straight to this device. Smaller is faster away from home."
                 : "Connect to the camera to export.")
                .type(.footnote, color: Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lengthLabel(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int(seconds / 60))M" : "\(Int(seconds))S"
    }

    // MARK: Progress

    @ViewBuilder
    private func progress(_ job: CameraConnection.ExportJob) -> some View {
        switch job.state {
        case .working:
            VStack(alignment: .leading, spacing: Space.l) {
                LED(Palette.accent, label: job.progress < 0.7 ? "Camera is cutting the clip" : "Receiving clip", pulsing: true)
                Numeral("\(Int((job.progress * 100).rounded()))", unit: "%",
                        caption: "\(job.from.timelineClock) → \(job.to.timelineClock)")
                ProgressBar(value: job.progress)
            }
            .panel(padding: Space.xl)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Exporting clip")
            .accessibilityValue("\(Int(job.progress * 100)) percent")

        case let .done(url):
            VStack(alignment: .leading, spacing: Space.l) {
                LED(Palette.ok, label: "Clip ready")
                Numeral(clipDuration.map { "\(Int($0.rounded()))" } ?? "–", unit: "S",
                        caption: "\(job.from.timelineClock) → \(job.to.timelineClock)")
                    .task { clipDuration = try? await AVURLAsset(url: url).load(.duration).seconds }
                ProgressBar(value: 1)
                if let clipDuration, clipDuration < job.to.timeIntervalSince(job.from) - 2 {
                    Text("Shorter than requested: the camera wasn't recording for part of that time.")
                        .type(.footnote, color: Palette.textSecondary)
                }
            }
            .panel(padding: Space.xl)

            VStack(spacing: Space.m) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary)

                Button {
                    Task {
                        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                        guard status == .authorized || status == .limited else { return }
                        try? await PHPhotoLibrary.shared().performChanges {
                            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                        }
                        saved = true
                    }
                } label: {
                    Label(saved ? "Saved to Photos" : "Save to Photos", systemImage: saved ? "checkmark" : "photo.on.rectangle")
                }
                .buttonStyle(.secondary)
                .disabled(saved)
                .macSaveAs(url, suggestedName: "\(connection.camera.name) \(job.from.formatted(.dateTime.year().month().day().hour().minute()))")
            }

        case let .failed(message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Export failed", message: message) {
                Button("Try again") {
                    connection.dismissExport(job.id)
                    jobID = nil
                }
                .buttonStyle(.primary)
                .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Thin accent progress bar.
private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.raised)
                Capsule().fill(Palette.accent)
                    .frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
        .animation(Motion.smooth, value: value)
        .accessibilityHidden(true)
    }
}

private extension ExportQuality {
    var shortLabel: String {
        switch self {
        case .original: "Orig"
        case .hd720: "720"
        case .sd540: "540"
        }
    }
}
