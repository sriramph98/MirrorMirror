import CoreAudio
import Foundation
import AVFAudio
import AudioToolbox
import CoreMedia
@preconcurrency import SoundAnalysis
import os

/// Loudness and sound-class detector for microphone buffers.
///
/// `process(sampleBuffer:)` computes the level on the caller's thread and hands a mono
/// Float32 copy of the audio to a private serial queue, which runs the loudness trigger and
/// Apple's built-in sound classifier. Settings and `level` are safe to touch from any thread.
final class SoundDetector: @unchecked Sendable {

    // MARK: Settings (thread-safe)

    var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    /// 0...1. Higher triggers on quieter sounds and less certain classifications.
    var sensitivity: Double {
        get { lock.withLock { _sensitivity } }
        set { lock.withLock { _sensitivity = min(max(newValue, 0), 1) } }
    }

    /// Kinds that may be reported; anything outside `EventKind.soundKinds` is ignored.
    var enabledKinds: Set<EventKind> {
        get { lock.withLock { _enabledKinds } }
        set { lock.withLock { _enabledKinds = newValue } }
    }

    /// Called on the detector's private queue.
    var onEvent: ((DetectionResult) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Smoothed loudness for a UI meter: -60 dBFS → 0, 0 dBFS → 1. Updated even when disabled.
    var level: Double { lock.withLock { _level } }

    // MARK: Tuning

    private static let cooldown: TimeInterval = 20      // per kind
    private static let sustainDuration = 0.5            // loudness must last this long
    private static let gapTolerance = 0.15              // short dips that don't break a loud stretch
    private static let classifierPreference = 1.0       // generic events wait this long for a classifier result
    private static let maxPendingBuffers = 64

    private static let classifiedKinds: Set<EventKind> = [.crying, .barking, .glassBreak, .alarm]

    /// sensitivity 0 → -12 dBFS, 0.5 → -25 dBFS, 1 → -40 dBFS.
    private static func loudnessThreshold(_ sensitivity: Double) -> Double {
        sensitivity <= 0.5 ? -12 - 26 * sensitivity : -25 - 30 * (sensitivity - 0.5)
    }

    /// sensitivity 0 → 0.85, 0.5 → 0.6, 1 → 0.35.
    private static func classificationThreshold(_ sensitivity: Double) -> Double {
        0.85 - 0.5 * sensitivity
    }

    private static func kind(forClassifierLabel identifier: String) -> EventKind? {
        let label = identifier.lowercased()
        if label.contains("glass_break") || label.contains("shatter") { return .glassBreak }
        if label.contains("crying") || label.contains("baby_cry") || label.contains("sobbing") { return .crying }
        if label.contains("dog") || label.contains("bark") { return .barking }
        if label.contains("smoke_detector") || label.contains("fire_alarm") || label.contains("siren")
            || label.contains("alarm") || label.contains("beep") {
            return .alarm
        }
        return nil
    }

    private static func label(for kind: EventKind) -> String {
        switch kind {
        case .crying: "Baby crying"
        case .barking: "Dog barking"
        case .glassBreak: "Glass breaking"
        case .alarm: "Alarm sounding"
        default: "Loud sound"
        }
    }

    // MARK: Lock-protected state

    private struct Settings {
        var isEnabled: Bool
        var sensitivity: Double
        var enabledKinds: Set<EventKind>
    }

    private let lock = NSLock()
    private var _isEnabled = true
    private var _sensitivity = 0.5
    private var _enabledKinds = Set(EventKind.soundKinds)
    private var _onEvent: ((DetectionResult) -> Void)?
    private var _level = 0.0
    private var pendingBuffers = 0

    private var settings: Settings {
        lock.withLock { Settings(isEnabled: _isEnabled, sensitivity: _sensitivity, enabledKinds: _enabledKinds) }
    }

    // MARK: Queue state

    private let queue = DispatchQueue(label: "Mira.SoundDetector", qos: .utility)
    private var analyzer: SNAudioStreamAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var observer: ClassificationObserver?
    private var framePosition: AVAudioFramePosition = 0
    private var classifierUnavailable = false
    private var loudDuration = 0.0
    private var quietDuration = 0.0
    private var genericPending = false
    private var lastClassifiedAt: TimeInterval = -.infinity
    private var lastEventAt: [EventKind: TimeInterval] = [:]
    private var generation = 0   // bumped by reset() to cancel delayed generic events
    private let logger = Logger(subsystem: "Mira", category: "SoundDetector")

    init() {}

    // MARK: Public API

    /// Call with every audio buffer from `AVCaptureAudioDataOutput`.
    func process(sampleBuffer: CMSampleBuffer) {
        guard let chunk = Self.monoChunk(from: sampleBuffer) else { return }
        let dbfs = 20 * log10(max(Double(chunk.rms), 1e-7))
        let target = min(max((dbfs + 60) / 60, 0), 1)

        let accepted: Bool = lock.withLock {
            // Fast attack, slow release, so the meter jumps on a sound and eases back down.
            _level += (target - _level) * (target > _level ? 0.5 : 0.1)
            guard _isEnabled, pendingBuffers < Self.maxPendingBuffers else { return false }
            pendingBuffers += 1
            return true
        }
        guard accepted else { return }

        queue.async { [self] in
            lock.withLock { pendingBuffers -= 1 }
            handle(chunk, dbfs: dbfs)
        }
    }

    /// Clears loudness tracking and the classifier stream, e.g. after an audio route change.
    func reset() {
        lock.withLock { _level = 0 }
        queue.async { [self] in
            generation += 1
            loudDuration = 0
            quietDuration = 0
            genericPending = false
            lastClassifiedAt = -.infinity
            tearDownAnalyzer()
        }
    }

    // MARK: Processing (private queue)

    private func handle(_ chunk: AudioChunk, dbfs: Double) {
        let settings = settings
        guard settings.isEnabled else { return }

        if settings.enabledKinds.contains(.sound) {
            trackLoudness(chunk, dbfs: dbfs, sensitivity: settings.sensitivity)
        }
        if !settings.enabledKinds.isDisjoint(with: Self.classifiedKinds) {
            classify(chunk)
        }
    }

    private func trackLoudness(_ chunk: AudioChunk, dbfs: Double, sensitivity: Double) {
        let duration = Double(chunk.samples.count) / chunk.sampleRate
        let threshold = Self.loudnessThreshold(sensitivity)
        if dbfs >= threshold {
            loudDuration += duration
            quietDuration = 0
        } else {
            quietDuration += duration
            if quietDuration > Self.gapTolerance { loudDuration = 0 }
        }
        guard loudDuration >= Self.sustainDuration else { return }
        loudDuration = 0

        let now = ProcessInfo.processInfo.systemUptime
        guard !genericPending, isReady(.sound, at: now),
              now - lastClassifiedAt > Self.classifierPreference else { return }

        // Hold the generic event briefly; if the classifier names the sound meanwhile, drop it.
        genericPending = true
        let scheduledAt = now
        let scheduledGeneration = generation
        let confidence = min(1, 0.5 + (dbfs - threshold) / 20)
        queue.asyncAfter(deadline: .now() + Self.classifierPreference) { [weak self] in
            guard let self, scheduledGeneration == generation else { return }
            genericPending = false
            let now = ProcessInfo.processInfo.systemUptime
            let settings = settings
            guard settings.isEnabled, settings.enabledKinds.contains(.sound),
                  lastClassifiedAt < scheduledAt - Self.classifierPreference,
                  isReady(.sound, at: now) else { return }
            emit(.sound, confidence: confidence, at: now)
        }
    }

    private func classify(_ chunk: AudioChunk) {
        guard !classifierUnavailable else { return }
        if analyzerFormat?.sampleRate != chunk.sampleRate {
            makeAnalyzer(sampleRate: chunk.sampleRate)
        }
        guard let analyzer, let analyzerFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(chunk.samples.count)
    }

    private func makeAnalyzer(sampleRate: Double) {
        tearDownAnalyzer()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let observer = ClassificationObserver(
                onResult: { [weak self] result in
                    guard let self else { return }
                    queue.async { self.handleClassification(result) }
                },
                onFailure: { [weak self] error in
                    guard let self else { return }
                    queue.async { self.disableClassifier(error) }
                }
            )
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.observer = observer
        } catch {
            disableClassifier(error)
        }
    }

    private func tearDownAnalyzer() {
        analyzer?.removeAllRequests()
        analyzer = nil
        analyzerFormat = nil
        observer = nil
        framePosition = 0
    }

    private func disableClassifier(_ error: Error) {
        guard !classifierUnavailable else { return }
        classifierUnavailable = true
        tearDownAnalyzer()
        logger.error("Sound classification unavailable, using loudness only: \(error.localizedDescription, privacy: .public)")
    }

    private func handleClassification(_ result: SNClassificationResult) {
        let settings = settings
        guard settings.isEnabled else { return }

        let threshold = Self.classificationThreshold(settings.sensitivity)
        var best: [EventKind: Double] = [:]
        for classification in result.classifications where classification.confidence >= threshold {
            guard let kind = Self.kind(forClassifierLabel: classification.identifier),
                  settings.enabledKinds.contains(kind) else { continue }
            best[kind] = max(best[kind] ?? 0, classification.confidence)
        }
        guard !best.isEmpty else { return }

        // Counts even during cooldown, so an ongoing bark doesn't resurface as "Loud sound".
        let now = ProcessInfo.processInfo.systemUptime
        lastClassifiedAt = now

        for (kind, confidence) in best.sorted(by: { $0.value > $1.value }) where isReady(kind, at: now) {
            emit(kind, confidence: confidence, at: now)
        }
    }

    private func isReady(_ kind: EventKind, at now: TimeInterval) -> Bool {
        guard let last = lastEventAt[kind] else { return true }
        return now - last >= Self.cooldown
    }

    private func emit(_ kind: EventKind, confidence: Double, at now: TimeInterval) {
        lastEventAt[kind] = now
        onEvent?(DetectionResult(kind: kind, label: Self.label(for: kind), confidence: confidence, snapshotJPEG: nil))
    }

    // MARK: PCM extraction

    private struct AudioChunk {
        var samples: [Float]   // mono, -1...1
        var sampleRate: Double
        var rms: Float         // across all channels
    }

    /// Copies linear PCM (Int16, Int32 or Float32; interleaved or not) into a mono Float32 chunk.
    private static func monoChunk(from sampleBuffer: CMSampleBuffer) -> AudioChunk? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mSampleRate > 0 else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, isFloat ? bits == 32 : (bits == 16 || bits == 32) else { return nil }
        let bytesPerSample = bits / 8

        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }

        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let listPointer = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        func sample(_ data: UnsafeRawPointer, _ index: Int) -> Float {
            if isFloat { return data.load(fromByteOffset: index * 4, as: Float.self) }
            if bits == 16 { return Float(data.load(fromByteOffset: index * 2, as: Int16.self)) / 32_768 }
            return Float(data.load(fromByteOffset: index * 4, as: Int32.self)) / 2_147_483_648
        }

        // The audio buffer list points into blockBuffer, so keep it alive while reading.
        return withExtendedLifetime(blockBuffer) { () -> AudioChunk? in
            let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
            let channelScale = 1 / Float(channels)
            var mono: [Float] = []
            var sumOfSquares: Float = 0
            var sampleCount = 0

            if isInterleaved {
                guard let first = buffers.first, let data = first.mData else { return nil }
                let frames = Int(first.mDataByteSize) / (bytesPerSample * channels)
                mono = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var mixed: Float = 0
                    for channel in 0..<channels {
                        let value = sample(data, frame * channels + channel)
                        sumOfSquares += value * value
                        mixed += value
                    }
                    mono[frame] = mixed * channelScale
                }
                sampleCount = frames * channels
            } else {
                let planes = buffers.prefix(channels).compactMap { buffer -> (UnsafeRawPointer, Int)? in
                    guard let data = buffer.mData else { return nil }
                    return (UnsafeRawPointer(data), Int(buffer.mDataByteSize) / bytesPerSample)
                }
                guard let frames = planes.map(\.1).min() else { return nil }
                let planeScale = 1 / Float(planes.count)
                mono = [Float](repeating: 0, count: frames)
                for (data, _) in planes {
                    for frame in 0..<frames {
                        let value = sample(data, frame)
                        sumOfSquares += value * value
                        mono[frame] += value * planeScale
                    }
                }
                sampleCount = frames * planes.count
            }

            guard sampleCount > 0, !mono.isEmpty else { return nil }
            return AudioChunk(samples: mono, sampleRate: asbd.mSampleRate, rms: (sumOfSquares / Float(sampleCount)).squareRoot())
        }
    }
}

private final class ClassificationObserver: NSObject, SNResultsObserving {
    private let onResult: (SNClassificationResult) -> Void
    private let onFailure: (Error) -> Void

    init(onResult: @escaping (SNClassificationResult) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onResult = onResult
        self.onFailure = onFailure
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        if let result = result as? SNClassificationResult { onResult(result) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onFailure(error)
    }
}
