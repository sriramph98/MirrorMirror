import SwiftUI
import AVFoundation
import Photos

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
        NavigationStack {
            Form {
                if let jobID, let job = connection.exports[jobID] {
                    progressSection(job)
                } else {
                    Section {
                        DatePicker("Ends at", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        HStack {
                            Button("−10 s") { end = end.addingTimeInterval(-10) }.buttonStyle(.bordered)
                            Spacer()
                            Text(end.formatted(date: .omitted, time: .standard)).monospacedDigit()
                            Spacer()
                            Button("+10 s") { end = min(Date(), end.addingTimeInterval(10)) }.buttonStyle(.bordered)
                        }
                        Picker("Length", selection: $duration) {
                            Text("10 seconds").tag(TimeInterval(10))
                            Text("30 seconds").tag(TimeInterval(30))
                            Text("1 minute").tag(TimeInterval(60))
                            Text("2 minutes").tag(TimeInterval(120))
                            Text("5 minutes").tag(TimeInterval(300))
                        }
                    } header: {
                        Text("Clip")
                    } footer: {
                        Text("\(start.formatted(date: .omitted, time: .standard)) – \(end.formatted(date: .omitted, time: .standard)). Footage from the last minute may still be recording; pick a slightly earlier end if the clip comes up short.")
                    }

                    Section {
                        Picker("Quality", selection: $quality) {
                            Text("Original").tag(ExportQuality.original)
                            Text("720p").tag(ExportQuality.hd720)
                            Text("540p (smallest)").tag(ExportQuality.sd540)
                        }
                    } footer: {
                        Text("The camera trims the clip and sends it straight to this device. Smaller is faster away from home.")
                    }

                    Section {
                        Button("Export Clip") {
                            jobID = connection.exportClip(from: start, to: end, quality: quality)
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(connection.phase != .connected)
                    }
                }
            }
            .navigationTitle("Export Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let jobID { connection.dismissExport(jobID) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Default: the 30 s around what's on screen.
                if let date = connection.playback.date, !connection.playback.isLive {
                    end = min(Date(), date.addingTimeInterval(15))
                } else {
                    end = Date().addingTimeInterval(-60)
                }
            }
        }
    }

    private var start: Date { end.addingTimeInterval(-duration) }

    @ViewBuilder
    private func progressSection(_ job: CameraConnection.ExportJob) -> some View {
        switch job.state {
        case .working:
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(job.progress < 0.7 ? "Camera is preparing the clip…" : "Receiving clip…")
                    ProgressView(value: job.progress)
                }
                .padding(.vertical, 8)
            }
        case let .done(url):
            Section {
                Label(clipDuration.map { "Clip ready · \(Int($0.rounded())) s" } ?? "Clip ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .task {
                        clipDuration = try? await AVURLAsset(url: url).load(.duration).seconds
                    }
                if let clipDuration, clipDuration < job.to.timeIntervalSince(job.from) - 2 {
                    Text("Shorter than requested: the camera wasn't recording for part of that time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
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
                .disabled(saved)
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") {
                    connection.dismissExport(job.id)
                    jobID = nil
                }
            }
        }
    }
}
