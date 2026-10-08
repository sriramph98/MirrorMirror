import Foundation

/// iPhone ⇄ Apple Watch protocol over WatchConnectivity. The link is Apple's encrypted
/// paired-device channel, so pairing keys can travel on it (the watch needs them to decrypt
/// iCloud snapshots when the iPhone is out of reach).
enum WatchLink {
    /// Application-context key carrying `[WatchCamera]` (JSON).
    static let camerasKey = "cameras"
    /// Message key carrying an encoded `WatchRequest` (watch → iPhone).
    static let requestKey = "request"
    /// Reply key carrying an encoded `WatchReply`.
    static let replyKey = "reply"

    /// First byte of binary messages.
    enum Payload: UInt8 {
        case frame = 1      // iPhone → watch: JPEG
        case voice = 2      // iPhone → watch: camera audio (VoiceCodec)
        case status = 3     // iPhone → watch: JSON WatchLiveStatus
        case talk = 4       // watch → iPhone: watch microphone (VoiceCodec)
    }

    static func pack(_ kind: Payload, _ data: Data) -> Data {
        var out = Data([kind.rawValue])
        out.append(data)
        return out
    }

    static func unpack(_ data: Data) -> (Payload, Data)? {
        guard let first = data.first, let kind = Payload(rawValue: first) else { return nil }
        return (kind, data.dropFirst())
    }
}

struct WatchCamera: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var key: PairingKey
}

enum WatchRequest: Codable {
    /// Start relaying a camera; `listen` also relays its audio.
    case watch(cameraID: String, listen: Bool)
    case listen(Bool)
    case talk(Bool)
    /// Keep-alive while the watch screen is showing a camera.
    case ping
    case stop
}

struct WatchReply: Codable {
    var ok: Bool
    var message: String?
}

struct WatchLiveStatus: Codable, Equatable {
    enum Phase: String, Codable { case connecting, live, playback, failed }
    var phase: Phase
    var detail: String?
    var batteryLevel: Double?
    var isRecording: Bool
    var nightActive: Bool
    var otherTalker: String?
}
