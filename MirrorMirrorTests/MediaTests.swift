import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import MirrorMirror

// MARK: - Fixtures

enum Fixtures {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A BGRA frame filled with `gray`, with an optional bright square (for motion).
    static func frame(width: Int = 640, height: Int = 360, gray: UInt8 = 60, square: CGRect? = nil) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let inSquare = square.map { $0.contains(CGPoint(x: x, y: y)) } ?? false
                let value: UInt8 = inSquare ? 240 : gray
                let p = base + y * stride + x * 4
                p[0] = value; p[1] = value; p[2] = value; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// NV12 frame (what the real camera produces).
    static func nv12Frame(width: Int, height: Int, luma: UInt8 = 128) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 0), Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * height)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Mono Float32 PCM sample buffer: a sine at `amplitude` (0 = silence).
    static func audio(amplitude: Float, frequency: Double = 440, sampleRate: Double = 48_000, frames: Int = 4_800, startFrame: Int = 0) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = amplitude * Float(sin(2 * .pi * frequency * Double(startFrame + i) / sampleRate))
        }
        var block: CMBlockBuffer?
        let byteCount = frames * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }
}

func waitUntil(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

/// Thread-safe collector for callbacks that fire on background queues.
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

// MARK: - Recording

@Suite("Recording, playback and export", .serialized)
struct RecordingTests {
    /// Feeds `seconds` of 30 fps frames with host-clock timestamps ending now.
    private func record(into store: RecordingStore, seconds: Double, segmentSeconds: TimeInterval, width: Int = 640, height: Int = 360) async {
        let recorder = SegmentRecorder(store: store)
        recorder.segmentDuration = segmentSeconds
        recorder.recordAudio = false
        recorder.start()
        let frameCount = Int(seconds * 30)
        let start = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: seconds, preferredTimescale: 600)
        for i in 0..<frameCount {
            let x = Double(i % 60) * 8
            recorder.append(pixelBuffer: Fixtures.frame(width: width, height: height, square: CGRect(x: x, y: 100, width: 80, height: 80)),
                            time: start + CMTime(value: CMTimeValue(i), timescale: 30))
            if i % 10 == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        recorder.stop()
        // stop() finishes the last partial segment asynchronously; wait for all of them.
        let expected = Int((seconds / segmentSeconds).rounded(.up))
        _ = await waitUntil(timeout: 15) { store.segmentsSnapshot().count >= expected }
    }

    @Test func recorderSplitsIntoSegmentsAndStorePersists() async throws {
        let dir = Fixtures.temporaryDirectory()
        let store = RecordingStore(directory: dir)
        await record(into: store, seconds: 6.5, segmentSeconds: 2)
        let segments = store.segmentsSnapshot()
        #expect(segments.count == 4)
        for segment in segments {
            #expect(segment.duration > 0.3 && segment.duration < 2.6)
            #expect(segment.width == 640 && segment.height == 360)
            #expect(FileManager.default.fileExists(atPath: store.url(for: segment).path))
            let asset = AVURLAsset(url: store.url(for: segment))
            #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        }
        store.flush()
        // A fresh store reading the same directory sees the same index.
        let reloaded = RecordingStore(directory: dir)
        #expect(reloaded.segmentsSnapshot().map(\.id) == segments.map(\.id))
    }

    @Test func locateFindsSegmentsAndGaps() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 4.2, segmentSeconds: 2)
        let segments = store.segmentsSnapshot()
        let first = try #require(segments.first)
        let found = try #require(store.locate(first.start.addingTimeInterval(1)))
        #expect(found.segment.id == first.id)
        #expect(abs(found.offset - 1) < 0.05)
        // Before all footage: the first segment from its start.
        let early = try #require(store.locate(first.start.addingTimeInterval(-100)))
        #expect(early.segment.id == first.id && early.offset == 0)
        #expect(store.locate(Date().addingTimeInterval(3600)) == nil)
    }

    @Test func eventsAndThumbnailsAreStored() throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        let event = store.addEvent(CameraEvent(date: Date(), kind: .person, label: "Person detected", confidence: 0.9),
                                   thumbnailJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let url = try #require(store.thumbnailURL(for: event))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.eventsSnapshot().count == 1)
        store.deleteEvent(event)
        #expect(store.eventsSnapshot().isEmpty)
    }

    @Test func storageCapDeletesOldestFirst() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 6.5, segmentSeconds: 2)
        let before = store.segmentsSnapshot()
        let newest = try #require(before.last)
        store.enforceRetention(capBytes: newest.byteSize + 1, mode: .continuous)
        let after = store.segmentsSnapshot()
        #expect(after.count == 1)
        #expect(after.first?.id == newest.id)
        _ = await waitUntil(timeout: 3) { !FileManager.default.fileExists(atPath: store.url(for: before[0]).path) }
        #expect(!FileManager.default.fileExists(atPath: store.url(for: before[0]).path))
    }

    @Test func eventsModeKeepsFootageAroundEventsOnly() throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        let old = Date().addingTimeInterval(-600)
        // Three fake 30 s segments ten minutes ago; an event inside the middle one.
        for i in 0..<3 {
            let start = old.addingTimeInterval(Double(i) * 30)
            let url = store.newSegmentURL(start: start)
            try Data(count: 1000).write(to: url)
            store.add(RecordingSegment(start: start, duration: 30, fileName: url.lastPathComponent, byteSize: 1000, width: 1, height: 1))
        }
        store.addEvent(CameraEvent(date: old.addingTimeInterval(45), kind: .motion, label: "Motion", confidence: 1), thumbnailJPEG: nil)
        store.enforceRetention(capBytes: 1_000_000_000, mode: .events)
        // Kept: the segment with the event, plus the one before it as pre-roll. Dropped: the one after.
        let kept = store.segmentsSnapshot()
        #expect(kept.count == 2)
        #expect(kept.contains { $0.contains(old.addingTimeInterval(45)) })
        #expect(!kept.contains { $0.contains(old.addingTimeInterval(75)) })
    }

    @Test func exportStitchesAcrossSegments() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 6.5, segmentSeconds: 2)
        let segments = store.segmentsSnapshot()
        let from = try #require(segments.first).start.addingTimeInterval(1)
        let to = from.addingTimeInterval(3)   // spans at least two segments
        let progress = Collector<Double>()
        let url = try await ClipExporter.export(from: from, to: to, store: store, quality: .original) { progress.append($0) }
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 3) < 0.3)
        #expect(progress.all.last == 1)

        let small = try await ClipExporter.export(from: from, to: to, store: store, quality: .sd540) { _ in }
        defer { try? FileManager.default.removeItem(at: small) }
        #expect(try await AVURLAsset(url: small).load(.duration).seconds > 2.5)
    }

    @Test func exportWithoutFootageFails() async {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await #expect(throws: (any Error).self) {
            _ = try await ClipExporter.export(from: Date().addingTimeInterval(-10), to: Date(), store: store, quality: .original) { _ in }
        }
    }

    @Test func stillImageAtDate() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 2.2, segmentSeconds: 2)
        let first = try #require(store.segmentsSnapshot().first)
        let jpeg = try await ClipExporter.still(at: first.start.addingTimeInterval(1), store: store, maxDimension: 320)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
    }

    @Test func playbackRunsAcrossSegmentsThenReachesLive() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 4.2, segmentSeconds: 2)
        let first = try #require(store.segmentsSnapshot().first)
        let reader = PlaybackReader(store: store)
        let frames = Collector<Date>()
        let reachedLive = Collector<Bool>()
        reader.onFrame = { buffer, date in
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            frames.append(date)
        }
        reader.onReachedLive = { reachedLive.append(true) }
        reader.rate = 4
        reader.play(from: first.start)
        #expect(await waitUntil(timeout: 8) { !reachedLive.all.isEmpty })
        let dates = frames.all
        #expect(dates.count > 20)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 <= $1 })
        #expect((dates.last ?? .distantPast) > first.end)  // crossed into the second segment
        reader.stop()
    }

    @Test func playbackPauseStopsFrames() async throws {
        let store = RecordingStore(directory: Fixtures.temporaryDirectory())
        await record(into: store, seconds: 4.2, segmentSeconds: 2)
        let reader = PlaybackReader(store: store)
        let frames = Collector<Date>()
        reader.onFrame = { _, date in frames.append(date) }
        reader.play(from: try #require(store.segmentsSnapshot().first).start)
        _ = await waitUntil(timeout: 3) { frames.all.count > 5 }
        reader.pause()
        try await Task.sleep(for: .milliseconds(300))
        let paused = frames.all.count
        try await Task.sleep(for: .milliseconds(700))
        #expect(frames.all.count <= paused + 1)
        reader.resume()
        #expect(await waitUntil(timeout: 3) { frames.all.count > paused + 5 })
        reader.stop()
    }
}

// MARK: - Detection

@Suite("Motion and sound detection", .serialized)
struct DetectionTests {
    private func feed(_ detector: MotionDetector, frames: Int, start: Int = 0, square: (Int) -> CGRect?, gray: UInt8 = 60) async {
        for i in start..<(start + frames) {
            detector.process(pixelBuffer: Fixtures.frame(gray: gray, square: square(i)), time: CMTime(value: CMTimeValue(i), timescale: 30))
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    @Test func movingObjectTriggersMotion() async {
        let detector = MotionDetector()
        detector.detectPeopleAndPets = false
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feed(detector, frames: 30, square: { _ in nil })           // learn an empty scene
        #expect(events.all.isEmpty)
        await feed(detector, frames: 60, start: 30) { i in CGRect(x: (i % 40) * 12, y: 80, width: 160, height: 160) }
        #expect(await waitUntil(timeout: 3) { !events.all.isEmpty })
        #expect(events.all.first?.kind == .motion)
        #expect(events.all.first?.snapshotJPEG?.starts(with: [0xFF, 0xD8]) == true)
        #expect(detector.activityLevel > 0)
    }

    @Test func staticSceneAndLightsSwitchingOnDoNotTrigger() async {
        let detector = MotionDetector()
        detector.detectPeopleAndPets = false
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feed(detector, frames: 30, square: { _ in nil }, gray: 40)
        await feed(detector, frames: 30, start: 30, square: { _ in nil }, gray: 200)  // whole frame brightens at once
        try? await Task.sleep(for: .milliseconds(500))
        #expect(events.all.isEmpty)
    }

    @Test func disabledDetectorIsSilent() async {
        let detector = MotionDetector()
        detector.isEnabled = false
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feed(detector, frames: 60) { i in i > 20 ? CGRect(x: (i % 40) * 12, y: 80, width: 160, height: 160) : nil }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(events.all.isEmpty)
    }

    @Test func cooldownLimitsRepeatEvents() async {
        let detector = MotionDetector()
        detector.detectPeopleAndPets = false
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feed(detector, frames: 30, square: { _ in nil })
        await feed(detector, frames: 150, start: 30) { i in CGRect(x: (i % 40) * 12, y: 80, width: 160, height: 160) }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(events.all.count == 1)
    }

    private func feedAudio(_ detector: SoundDetector, amplitude: Float, seconds: Double) async {
        let chunk = 4_800
        for i in 0..<Int(seconds * 10) {
            detector.process(sampleBuffer: Fixtures.audio(amplitude: amplitude, frames: chunk, startFrame: i * chunk))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func loudSoundTriggersAndSilenceDoesNot() async {
        let detector = SoundDetector()
        detector.enabledKinds = [.sound]
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feedAudio(detector, amplitude: 0, seconds: 1)
        #expect(events.all.isEmpty)
        #expect(detector.level < 0.1)
        await feedAudio(detector, amplitude: 0.8, seconds: 2.5)
        #expect(await waitUntil(timeout: 3) { !events.all.isEmpty })
        #expect(events.all.first?.kind == .sound)
        #expect(detector.level > 0.5)
    }

    @Test func soundKindsCanBeDisabled() async {
        let detector = SoundDetector()
        detector.enabledKinds = []
        let events = Collector<DetectionResult>()
        detector.onEvent = { events.append($0) }
        await feedAudio(detector, amplitude: 0.8, seconds: 2.5)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(events.all.isEmpty)
    }
}

// MARK: - Frame processing

@Suite("Frame processing")
struct FrameProcessingTests {
    @Test func oversizedFramesAreScaledToPreset() throws {
        let processor = FrameProcessor()
        processor.targetLongEdge = 1280
        let output = try #require(processor.process(Fixtures.nv12Frame(width: 1920, height: 1080), enhance: false))
        #expect(CVPixelBufferGetWidth(output) == 1280)
        #expect(CVPixelBufferGetHeight(output) == 720)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    @Test func portraitFramesKeepOrientation() throws {
        let processor = FrameProcessor()
        processor.targetLongEdge = 1280
        let output = try #require(processor.process(Fixtures.nv12Frame(width: 1080, height: 1920), enhance: false))
        #expect(CVPixelBufferGetWidth(output) == 720)
        #expect(CVPixelBufferGetHeight(output) == 1280)
    }

    @Test func framesWithinPresetPassThrough() {
        let processor = FrameProcessor()
        processor.targetLongEdge = 1920
        #expect(processor.process(Fixtures.nv12Frame(width: 1280, height: 720), enhance: false) == nil)
    }

    @Test func nightEnhancementBrightensDarkFrames() throws {
        let processor = FrameProcessor()
        let dark = Fixtures.nv12Frame(width: 640, height: 360, luma: 30)
        let output = try #require(processor.process(dark, enhance: true))
        #expect(FrameProcessor.averageLuma(output) > FrameProcessor.averageLuma(dark) + 0.05)
    }

    @Test func averageLumaReadsBothFormats() {
        #expect(abs(FrameProcessor.averageLuma(Fixtures.nv12Frame(width: 320, height: 240, luma: 255)) - 1) < 0.01)
        #expect(FrameProcessor.averageLuma(Fixtures.frame(width: 320, height: 240, gray: 0)) < 0.01)
    }

    @Test func syntheticCameraProducesMovingFrames() {
        let source = SyntheticFrameSource()
        var frames: [CVPixelBuffer] = []
        for _ in 0..<5 { if let f = source.nextFrame(nightActive: false) { frames.append(f) } }
        #expect(frames.count == 5)
        #expect(CVPixelBufferGetWidth(frames[0]) == 1280)
    }
}
