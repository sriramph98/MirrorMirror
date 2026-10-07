import AVFoundation
import CoreMedia
import UIKit


enum ClipExportError: LocalizedError {
    case invalidRange
    case noFootage
    case exportFailed(String)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidRange: "The clip's end time must be after its start time."
        case .noFootage: "There's no recorded footage in that time range."
        case .exportFailed(let reason): "The clip couldn't be exported: \(reason)"
        case .imageEncodingFailed: "The still image couldn't be encoded."
        }
    }
}

enum ClipExporter {
    private static let timescale: CMTimeScale = 600

    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Stitches the segments overlapping `[from, to]` into one MP4 in the temporary directory.
    /// Gaps between segments are skipped. Progress (0...1) is reported from a background task.
    static func export(
        from: Date,
        to: Date,
        store: RecordingStore,
        quality: ExportQuality,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard to > from else { throw ClipExportError.invalidRange }
        let overlapping = store.segmentsSnapshot().filter { $0.end > from && $0.start < to }
        guard !overlapping.isEmpty else { throw ClipExportError.noFootage }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipExportError.exportFailed("Couldn't create a video track.")
        }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted: [(segment: RecordingSegment, range: CMTimeRange)] = []

        for segment in overlapping {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: store.url(for: segment))
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let assetDuration = try? await asset.load(.duration) else { continue }

            let startOffset = max(0, from.timeIntervalSince(segment.start))
            let endOffset = min(min(segment.duration, assetDuration.seconds), to.timeIntervalSince(segment.start))
            guard endOffset > startOffset else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: startOffset, preferredTimescale: timescale),
                end: CMTime(seconds: endOffset, preferredTimescale: timescale))

            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            } catch {
                continue
            }

            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioRange = try? await sourceAudio.load(.timeRange) {
                let clipped = range.intersection(audioRange)
                if clipped.duration > .zero {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(
                            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    if let audioTrack {
                        let at = cursor + (clipped.start - range.start)
                        // Keep audio aligned with video across segments that had no audio.
                        let audioEnd = audioTrack.timeRange.end.isValid ? audioTrack.timeRange.end : .zero
                        if at > audioEnd {
                            audioTrack.insertEmptyTimeRange(CMTimeRange(start: audioEnd, end: at))
                        }
                        try? audioTrack.insertTimeRange(clipped, of: sourceAudio, at: at)
                    }
                }
            }

            inserted.append((segment, CMTimeRange(start: cursor, duration: range.duration)))
            cursor = cursor + range.duration
        }

        guard !inserted.isEmpty else { throw ClipExportError.noFootage }
        videoTrack.preferredTransform = .identity

        let dimensions = Set(inserted.map { "\($0.segment.width)x\($0.segment.height)" })
        let mixedDimensions = dimensions.count > 1
        let preset: String = switch quality {
        case .original: mixedDimensions ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetPassthrough
        case .hd720: AVAssetExportPreset1280x720
        case .sd540: AVAssetExportPreset960x540
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ClipExportError.exportFailed("Export preset \(preset) is unavailable.")
        }
        if mixedDimensions && preset != AVAssetExportPresetPassthrough {
            session.videoComposition = fittingVideoComposition(for: videoTrack, pieces: inserted, total: cursor)
        }

        let name = "MirrorMirror-\(fileNameFormatter.string(from: from)).mp4"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: outputURL)

        progress(0)
        let progressTask = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state {
                    progress(p.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if error is CancellationError { throw error }
            throw ClipExportError.exportFailed(error.localizedDescription)
        }
        progress(1)
        return outputURL
    }

    /// A JPEG (quality 0.85) of the frame at `date`, scaled to fit `maxDimension`.
    static func still(at date: Date, store: RecordingStore, maxDimension: CGFloat) async throws -> Data {
        guard let (segment, offset) = store.locate(date) else { throw ClipExportError.noFootage }
        let asset = AVURLAsset(url: store.url(for: segment))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        // Stay inside the last frame; a zero-tolerance request past it fails.
        let clamped = max(0, min(offset, segment.duration - 0.05))
        let image = try await generator.image(at: CMTime(seconds: clamped, preferredTimescale: timescale)).image
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
            throw ClipExportError.imageEncodingFailed
        }
        return data
    }

    /// Aspect-fits every piece into the dimensions that cover most of the clip.
    private static func fittingVideoComposition(
        for track: AVCompositionTrack,
        pieces: [(segment: RecordingSegment, range: CMTimeRange)],
        total: CMTime
    ) -> AVVideoComposition {
        var coverage: [String: (size: CGSize, seconds: Double)] = [:]
        for piece in pieces {
            let key = "\(piece.segment.width)x\(piece.segment.height)"
            let size = CGSize(width: piece.segment.width, height: piece.segment.height)
            coverage[key, default: (size, 0)].seconds += piece.range.duration.seconds
        }
        let renderSize = coverage.values.max { $0.seconds < $1.seconds }?.size ?? CGSize(width: 1920, height: 1080)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        for piece in pieces {
            let source = CGSize(width: piece.segment.width, height: piece.segment.height)
            let scale = min(renderSize.width / source.width, renderSize.height / source.height)
            let tx = (renderSize.width - source.width * scale) / 2
            let ty = (renderSize.height - source.height * scale) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(transform, at: piece.range.start)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }
}
