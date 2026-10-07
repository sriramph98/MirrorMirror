import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Writes the live camera feed into fixed-length MP4 segments and hands each finished
/// segment to a `RecordingStore`. All writer work happens on one private serial queue.
final class SegmentRecorder {
    private static let log = Logger(subsystem: "MirrorMirror", category: "SegmentRecorder")
    /// A PTS jump larger than this means capture was interrupted; start a new segment so the
    /// file doesn't contain a frozen frame spanning the gap.
    private static let maxFrameGap: Double = 1.0
    /// Max video frames queued for the writer before new ones are dropped, so a slow writer
    /// can't starve the camera's buffer pool.
    private static let maxPendingFrames = 3
    /// How long to wait for the first audio buffer (to learn its format) before starting a
    /// segment without audio.
    private static let audioFormatWait: Double = 1.0

    private let store: RecordingStore
    private let queue = DispatchQueue(label: "SegmentRecorder.writer", qos: .userInitiated)

    // MARK: Configuration (guarded by `lock`, readable from any thread)

    private let lock = NSLock()
    private var _segmentDuration: TimeInterval = 60
    private var _recordAudio = true
    private var _bitrateForDimensions: (Int, Int) -> Int = SegmentRecorder.defaultBitrate
    private var _isRecording = false
    private var _onStateChange: ((Bool) -> Void)?
    private var pendingFrames = 0

    var segmentDuration: TimeInterval {
        get { lock.withLock { _segmentDuration } }
        set { lock.withLock { _segmentDuration = max(1, newValue) } }
    }

    var recordAudio: Bool {
        get { lock.withLock { _recordAudio } }
        set { lock.withLock { _recordAudio = newValue } }
    }

    var bitrateForDimensions: (Int, Int) -> Int {
        get { lock.withLock { _bitrateForDimensions } }
        set { lock.withLock { _bitrateForDimensions = newValue } }
    }

    var isRecording: Bool { lock.withLock { _isRecording } }

    var onStateChange: ((Bool) -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    /// HEVC at ~0.05 bits per pixel per frame at 30 fps (1080p ≈ 3.1 Mbps), clamped to 1–10 Mbps.
    static func defaultBitrate(width: Int, height: Int) -> Int {
        let bits = Double(width * height) * 30 * 0.05
        return Int(min(max(bits, 1_000_000), 10_000_000))
    }

    // MARK: Writer state (queue only)

    private struct ActiveSegment {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioInput: AVAssetWriterInput?
        let url: URL
        let startDate: Date
        let startPTS: CMTime
        let width: Int
        let height: Int
        var lastPTS: CMTime
        var frameDuration: Double = 1.0 / 30
        var frameCount = 0
    }

    private var active: ActiveSegment?
    private var queueRecording = false
    private var audioSampleRate: Double?
    private var audioWaitStart: CMTime?
    private var audioWaitDone = false

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Control

    func start() {
        let (changed, callback) = lock.withLock { () -> (Bool, ((Bool) -> Void)?) in
            guard !_isRecording else { return (false, nil) }
            _isRecording = true
            return (true, _onStateChange)
        }
        guard changed else { return }
        queue.async {
            self.queueRecording = true
            self.audioWaitStart = nil
            self.audioWaitDone = false
        }
        callback?(true)
    }

    /// Finishes the current segment asynchronously; it is added to the store once written.
    func stop() {
        let (changed, callback) = lock.withLock { () -> (Bool, ((Bool) -> Void)?) in
            guard _isRecording else { return (false, nil) }
            _isRecording = false
            return (true, _onStateChange)
        }
        guard changed else { return }
        queue.async {
            self.queueRecording = false
            self.finishActive()
        }
        callback?(false)
    }

    // MARK: Input

    func append(pixelBuffer: CVPixelBuffer, time: CMTime) {
        let accepted: Bool = lock.withLock {
            guard _isRecording, pendingFrames < Self.maxPendingFrames else { return false }
            pendingFrames += 1
            return true
        }
        guard accepted else { return }
        queue.async {
            self.lock.withLock { self.pendingFrames -= 1 }
            self.handleVideo(pixelBuffer, pts: time)
        }
    }

    func append(audio sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        queue.async { self.handleAudio(sampleBuffer) }
    }

    // MARK: Video

    private func handleVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard queueRecording, pts.isValid else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if let current = active {
            if current.writer.status == .failed || current.writer.status == .cancelled {
                Self.log.error("Writer failed: \(current.writer.error?.localizedDescription ?? "unknown error"); discarding segment")
                discardActive()
            } else if pts <= current.lastPTS {
                return // out of order or duplicate
            } else if width != current.width || height != current.height
                        || (pts - current.startPTS).seconds >= segmentDuration
                        || (pts - current.lastPTS).seconds > Self.maxFrameGap {
                finishActive()
            }
        }

        if active == nil {
            // After start(), wait briefly for the first audio buffer so the first segment can
            // include audio. Only once per start(), so a missing mic doesn't cost a second per segment.
            if recordAudio, audioSampleRate == nil, !audioWaitDone {
                let since = audioWaitStart ?? pts
                audioWaitStart = since
                if (pts - since).seconds < Self.audioFormatWait { return }
            }
            audioWaitDone = true
            guard startSegment(width: width, height: height, pts: pts) else { return }
        }

        guard var segment = active else { return }
        guard segment.videoInput.isReadyForMoreMediaData else { return }
        if segment.adaptor.append(pixelBuffer, withPresentationTime: pts) {
            if segment.frameCount > 0 {
                let delta = (pts - segment.lastPTS).seconds
                segment.frameDuration = min(max(delta, 1.0 / 120), 0.2)
            }
            segment.lastPTS = pts
            segment.frameCount += 1
            active = segment
        } else if segment.writer.status == .failed {
            Self.log.error("Video append failed: \(segment.writer.error?.localizedDescription ?? "unknown error")")
            discardActive()
        }
    }

    private func startSegment(width: Int, height: Int, pts: CMTime) -> Bool {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let startDate = Date().addingTimeInterval(-(hostNow - pts).seconds)
        let url = store.newSegmentURL(start: startDate)
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            Self.log.error("Could not create writer: \(error.localizedDescription)")
            return false
        }
        writer.shouldOptimizeForNetworkUse = false

        let bitrate = bitrateForDimensions(width, height)
        guard let videoInput = makeVideoInput(for: writer, width: width, height: height, bitrate: bitrate) else {
            Self.log.error("No usable video encoder for \(width)x\(height)")
            return false
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        var audioInput: AVAssetWriterInput?
        if recordAudio, let sampleRate = audioSampleRate {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            if writer.canApply(outputSettings: settings, forMediaType: .audio) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
            if audioInput == nil {
                Self.log.error("Audio input rejected; recording segment without audio")
            }
        }

        guard writer.startWriting() else {
            Self.log.error("startWriting failed: \(writer.error?.localizedDescription ?? "unknown error")")
            try? FileManager.default.removeItem(at: url)
            return false
        }
        writer.startSession(atSourceTime: pts)

        active = ActiveSegment(
            writer: writer, videoInput: videoInput, adaptor: adaptor, audioInput: audioInput,
            url: url, startDate: startDate, startPTS: pts, width: width, height: height, lastPTS: pts)
        return true
    }

    /// HEVC when the writer accepts it, otherwise H.264 at 1.5× the bitrate.
    private func makeVideoInput(for writer: AVAssetWriter, width: Int, height: Int, bitrate: Int) -> AVAssetWriterInput? {
        let candidates: [(AVVideoCodecType, Int, [String: Any])] = [
            (.hevc, bitrate, [:]),
            (.h264, min(bitrate * 3 / 2, 15_000_000), [AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]),
        ]
        for (codec, rate, extra) in candidates {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ]
            compression.merge(extra) { $1 }
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { continue }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { return input }
        }
        return nil
    }

    // MARK: Audio

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        if audioSampleRate == nil,
           let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           asbd.mSampleRate > 0 {
            audioSampleRate = asbd.mSampleRate
        }
        guard queueRecording, let segment = active, let input = segment.audioInput,
              segment.writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts >= segment.startPTS, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer), segment.writer.status == .failed {
            Self.log.error("Audio append failed: \(segment.writer.error?.localizedDescription ?? "unknown error")")
            discardActive()
        }
    }

    // MARK: Finishing

    private func finishActive() {
        guard let segment = active else { return }
        active = nil

        guard segment.frameCount > 0, segment.writer.status == .writing else {
            segment.writer.cancelWriting()
            try? FileManager.default.removeItem(at: segment.url)
            return
        }

        let duration = (segment.lastPTS - segment.startPTS).seconds + segment.frameDuration
        let endTime = segment.lastPTS + CMTime(seconds: segment.frameDuration, preferredTimescale: 600_000)
        segment.videoInput.markAsFinished()
        segment.audioInput?.markAsFinished()
        segment.writer.endSession(atSourceTime: endTime)

        let writer = segment.writer
        let store = store
        writer.finishWriting {
            guard writer.status == .completed else {
                Self.log.error("finishWriting failed: \(writer.error?.localizedDescription ?? "unknown error")")
                try? FileManager.default.removeItem(at: segment.url)
                return
            }
            let size = (try? segment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else {
                try? FileManager.default.removeItem(at: segment.url)
                return
            }
            store.add(RecordingSegment(
                start: segment.startDate,
                duration: duration,
                fileName: segment.url.lastPathComponent,
                byteSize: Int64(size),
                width: segment.width,
                height: segment.height))
        }
    }

    private func discardActive() {
        guard let segment = active else { return }
        active = nil
        if segment.writer.status == .writing { segment.writer.cancelWriting() }
        try? FileManager.default.removeItem(at: segment.url)
    }
}
