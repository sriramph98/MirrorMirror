import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Replays recorded footage frame by frame at `rate` × real time, crossing segment boundaries
/// (and skipping gaps) until it catches up with the newest stored segment.
final class PlaybackReader {
    private static let log = Logger(subsystem: "Mira", category: "PlaybackReader")
    private static let maxDeliveredFPS: Double = 30
    /// Falling further behind schedule than this re-anchors the clock instead of bursting frames.
    private static let maxLag: TimeInterval = 0.25
    /// Gaps between segments shorter than this keep the clock running; longer ones are skipped.
    private static let gapThreshold: TimeInterval = 1

    private let store: RecordingStore
    private let queue = DispatchQueue(label: "PlaybackReader", qos: .userInitiated)

    // MARK: Thread-safe state (guarded by `lock`)

    private let lock = NSLock()
    private var _rate: Double = 1
    private var _currentDate: Date?
    private var _session = 0
    private var _onFrame: ((CVPixelBuffer, Date) -> Void)?
    private var _onReachedLive: (() -> Void)?

    /// Called on the reader's private queue.
    var onFrame: ((CVPixelBuffer, Date) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Called on the reader's private queue once playback runs out of recorded footage.
    var onReachedLive: (() -> Void)? {
        get { lock.withLock { _onReachedLive } }
        set { lock.withLock { _onReachedLive = newValue } }
    }

    private(set) var currentDate: Date? {
        get { lock.withLock { _currentDate } }
        set { lock.withLock { _currentDate = newValue } }
    }

    var rate: Double {
        get { lock.withLock { _rate } }
        set {
            let clamped = min(max(newValue, 0.25), 16)
            lock.withLock { _rate = clamped }
            queue.async { self.restartClock() }
        }
    }

    // MARK: Queue-only state

    private struct Frame {
        let buffer: CVPixelBuffer
        let date: Date
    }

    private var session = 0           // mirrors `_session` for the queue's own bookkeeping
    private var isActive = false
    private var isPaused = false
    private var isOpening = false
    private var tick = 0              // invalidates scheduled pumps when the clock restarts
    private var segment: RecordingSegment?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: Frame?       // decoded, waiting for its delivery time
    private var lastDelivered: Date?
    private var anchorDate = Date()
    private var anchorUptime: TimeInterval = 0

    init(store: RecordingStore) {
        self.store = store
    }

    deinit {
        reader?.cancelReading()
    }

    // MARK: Control

    /// Starts playback at `date`, or seeks if already playing.
    func play(from date: Date) {
        let token = lock.withLock { () -> Int in
            _session += 1
            return _session
        }
        queue.async {
            guard self.lock.withLock({ self._session == token }) else { return } // superseded
            self.teardown()
            self.session = token
            guard let (segment, offset) = self.store.locate(date) else {
                self.reachedLive()
                return
            }
            self.isActive = true
            self.isPaused = false
            let start = segment.start.addingTimeInterval(offset)
            self.currentDate = start
            self.setAnchor(start)
            self.open(segment, offset: offset)
        }
    }

    func pause() {
        queue.async {
            guard self.isActive, !self.isPaused else { return }
            self.isPaused = true
            self.tick += 1
        }
    }

    func resume() {
        queue.async {
            guard self.isActive, self.isPaused else { return }
            self.isPaused = false
            self.restartClock()
        }
    }

    /// Safe to call repeatedly and from any thread, including from `onFrame`.
    func stop() {
        lock.withLock { _session += 1 }
        queue.async {
            self.teardown()
            self.currentDate = nil
        }
    }

    // MARK: Pump

    private var isCurrentSession: Bool {
        lock.withLock { _session == session }
    }

    private func setAnchor(_ date: Date) {
        anchorDate = date
        anchorUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Re-anchors the clock at the next frame (or current position) and restarts the pump.
    private func restartClock() {
        guard isActive, !isPaused else { return }
        setAnchor(pending?.date ?? lastDelivered ?? anchorDate)
        tick += 1
        pump(tick)
    }

    private func pump(_ token: Int) {
        guard token == tick, isActive, !isPaused, !isOpening else { return }
        guard isCurrentSession else { teardown(); return }

        if pending == nil {
            pending = readFrame()
        }
        guard let frame = pending else {
            advanceSegment()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let due = anchorUptime + frame.date.timeIntervalSince(anchorDate) / rate
        let delay = due - now
        if delay > 0.002 {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pump(token) }
            return
        }
        if -delay > Self.maxLag {
            setAnchor(frame.date)
        }

        pending = nil
        lastDelivered = frame.date
        currentDate = frame.date
        onFrame?(frame.buffer, frame.date)
        queue.async { [weak self] in self?.pump(token) }
    }

    /// Next frame from the open reader, skipping frames at high rates. nil when exhausted.
    private func readFrame() -> Frame? {
        guard let reader, let output, let segment, reader.status == .reading else { return nil }
        let currentRate = rate
        let minSpacing = currentRate > 2 ? currentRate / Self.maxDeliveredFPS * 0.9 : 0

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { continue }
            let date = segment.start.addingTimeInterval(pts.seconds)
            if let last = lastDelivered, date.timeIntervalSince(last) < minSpacing { continue }
            return Frame(buffer: buffer, date: date)
        }
        if reader.status == .failed {
            Self.log.error("Reading \(segment.fileName) failed: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        closeReader()
        return nil
    }

    private func advanceSegment() {
        let current = segment
        let next = store.segmentsSnapshot().first { candidate in
            guard let current else { return true }
            return candidate.start > current.start && candidate.id != current.id
        }
        guard let next else {
            reachedLive()
            return
        }
        if let current, next.start.timeIntervalSince(current.end) > Self.gapThreshold {
            setAnchor(next.start)
        }
        open(next, offset: 0)
    }

    // MARK: Reader lifecycle

    private func open(_ target: RecordingSegment, offset: TimeInterval) {
        closeReader()
        segment = target
        isOpening = true
        let token = session
        let asset = AVURLAsset(url: store.url(for: target))
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, error in
            guard let self else { return }
            self.queue.async {
                guard token == self.session, self.isActive, self.segment?.id == target.id else { return }
                self.isOpening = false
                if let track = tracks?.first {
                    self.startReading(asset: asset, track: track, segment: target, offset: offset)
                } else {
                    Self.log.error("No video in \(target.fileName): \(error?.localizedDescription ?? "missing track")")
                }
                // On failure `reader` stays nil, so the pump moves on to the next segment.
                self.tick += 1
                self.pump(self.tick)
            }
        }
    }

    private func startReading(asset: AVAsset, track: AVAssetTrack, segment: RecordingSegment, offset: TimeInterval) {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                Self.log.error("Reader rejected output for \(segment.fileName)")
                return
            }
            reader.add(output)
            if offset > 0 {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: offset, preferredTimescale: 600), duration: .positiveInfinity)
            }
            guard reader.startReading() else {
                Self.log.error("startReading failed for \(segment.fileName): \(reader.error?.localizedDescription ?? "unknown error")")
                return
            }
            self.reader = reader
            self.output = output
        } catch {
            Self.log.error("Could not open \(segment.fileName): \(error.localizedDescription)")
        }
    }

    private func closeReader() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }

    private func reachedLive() {
        let callback = onReachedLive
        teardown()
        currentDate = nil
        callback?()
    }

    private func teardown() {
        closeReader()
        isActive = false
        isPaused = false
        isOpening = false
        tick += 1
        segment = nil
        pending = nil
        lastDelivered = nil
    }
}
