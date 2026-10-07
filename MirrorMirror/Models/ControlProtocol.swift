import Foundation

/// Viewer → camera, JSON over the "control" data channel.
enum ViewerCommand: Codable {
    case hello(viewerID: String, name: String)
    case setLens(Double)
    case setZoom(Double)
    case flipCamera
    case setTorch(Bool)
    case setNightMode(NightMode)
    case setQuality(QualityPreset)
    case setRecording(Bool)
    case updateSettings(CameraSettings)
    case talk(Bool)
    case requestTimeline
    case playback(from: Date)
    case playbackPause
    case playbackResume
    case playbackRate(Double)
    case goLive
    case exportClip(requestID: UUID, from: Date, to: Date, quality: ExportQuality)
    case requestThumbnail(eventID: UUID)
    case requestSnapshot(requestID: UUID)
    case ping(Date)
    /// In-band SDP offer, used to open/close the viewer's microphone for talk-back
    /// without a new signaling round trip.
    case renegotiate(sdp: String)
    /// Send camera audio as voice packets on the voice channel (Apple Watch listening via iPhone).
    case relayVoice(Bool)
}

/// Camera → viewer, JSON over the "control" data channel.
enum CameraMessage: Codable {
    case welcome(cameraName: String)
    case rejected(reason: String)
    case status(CameraStatus)
    case event(CameraEvent)
    case timeline(segments: [RecordingSegment], events: [CameraEvent])
    case playbackState(date: Date?, isPlaying: Bool, isLive: Bool, rate: Double)
    case exportProgress(requestID: UUID, progress: Double)
    case exportFailed(requestID: UUID, message: String)
    case talkState(viewerName: String?)
    case pong(Date)
    case renegotiated(sdp: String)
}

/// Header sent as a text message on the "files" channel before the binary chunks of a file.
struct FileTransferHeader: Codable {
    enum Kind: String, Codable { case thumbnail, clip, snapshot }
    var id: UUID
    var kind: Kind
    var reference: UUID       // event ID for thumbnails, request ID for clips and snapshots
    var fileName: String
    var size: Int
}

struct FileTransferFooter: Codable {
    var id: UUID
}
