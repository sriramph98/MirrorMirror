import Foundation
import AVFoundation
import WebRTC

/// One connected viewer as seen from the camera: its peer connection, its own video source
/// (so it can watch live or replay recordings independently of other viewers), and an
/// optional playback reader.
final class ViewerSession {
    let id: UUID
    let viewerID: String
    private(set) var viewerName: String
    let link: PeerLink
    let injector: FrameInjector
    var videoSender: RTCRtpSender?
    var remoteAudio: RTCAudioTrack?
    var helloReceived = false
    var isTalking = false
    let connectedAt = Date()

    private let lock = NSLock()
    private var _isLive = true
    var isLive: Bool { lock.withLock { _isLive } }
    private(set) var playback: PlaybackReader?
    private var playbackRate: Double = 1

    init(id: UUID, viewerID: String, viewerName: String, link: PeerLink) {
        self.id = id
        self.viewerID = viewerID
        self.viewerName = viewerName
        self.link = link
        self.injector = FrameInjector(trackID: "video-\(id.uuidString.prefix(8))")
    }

    func rename(_ name: String) { viewerName = name }

    /// Live frames from the capture queue. Skipped while this viewer is replaying.
    func pushLive(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        if isLive { injector.push(pixelBuffer, time: time) }
    }

    func apply(quality: QualityPreset, portrait: Bool) {
        injector.adapt(to: quality, portrait: portrait)
        guard let sender = videoSender else { return }
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: quality.maxBitrate)
            encoding.maxFramerate = NSNumber(value: quality.fps)
        }
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        sender.parameters = parameters
    }

    // MARK: Playback

    func startPlayback(from date: Date, store: RecordingStore, onStateChange: @escaping (Date?, Bool, Bool, Double) -> Void) {
        let reader = playback ?? PlaybackReader(store: store)
        reader.rate = playbackRate
        reader.onFrame = { [weak self] buffer, _ in
            self?.injector.push(buffer, time: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        reader.onReachedLive = { [weak self] in
            guard let self else { return }
            self.goLive()
            onStateChange(nil, true, true, 1)
        }
        lock.withLock { _isLive = false }
        playback = reader
        reader.play(from: date)
        onStateChange(date, true, false, playbackRate)
    }

    func pausePlayback() { playback?.pause() }
    func resumePlayback() { playback?.resume() }

    func setRate(_ rate: Double) {
        playbackRate = rate
        playback?.rate = rate
    }

    func goLive() {
        playback?.stop()
        playback = nil
        playbackRate = 1
        lock.withLock { _isLive = true }
    }

    var playbackDate: Date? { playback?.currentDate }

    func close() {
        playback?.stop()
        playback = nil
        link.close()
    }
}

struct KnownViewer: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var firstSeen: Date
    var lastSeen: Date
    var blocked: Bool = false
}
