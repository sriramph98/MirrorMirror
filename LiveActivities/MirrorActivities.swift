import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents

// Compiled into the app and the widget extension. The app starts and updates these
// activities while it runs (there is no server, so nothing updates them remotely); the
// widget extension draws them on the Lock Screen, in the Dynamic Island and in the Apple
// Watch Smart Stack.

// MARK: - Viewer: the camera you're listening to

struct MonitorActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Link: String, Codable, Hashable { case live, reconnecting }

        var link: Link
        var isMuted: Bool
        /// 0…1 on a perceptual scale (see `LiveActivityFormat.meterLevel`).
        var soundLevel: Double
        /// "Local", "Direct" or "Relay"; nil until known.
        var path: String?
        var cameraRecording: Bool
        var cameraBattery: Double?
        /// Someone else talking through the camera.
        var otherTalker: String?
        var isTalking: Bool
        var lastEvent: ActivityEvent?
    }

    var cameraID: String
    var cameraName: String
}

// MARK: - Camera: this phone is the camera

struct CameraActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// iOS stops the camera while the app is off screen; viewers still hear the microphone.
        var isPaused: Bool
        var isRecording: Bool
        var recordingMode: RecordingMode
        var viewerCount: Int
        var viewerNames: [String]
        var talker: String?
        var battery: Double?
        var isCharging: Bool
        var isHot: Bool
        var lastEvent: ActivityEvent?
    }

    var cameraName: String
    var startedAt: Date
}

/// The latest motion or sound event, small enough for an activity payload.
struct ActivityEvent: Codable, Hashable {
    var kind: EventKind
    var label: String
    var date: Date
}

// MARK: - Buttons

/// Lock Screen and Dynamic Island buttons run in the app's process (launching it in the
/// background if needed). The widget extension only needs the types to build the buttons.
enum LiveActivityActions {
    enum Action: Sendable {
        case toggleMute(cameraID: String)
        case stopTalking(cameraID: String)
        case stopMonitoring(cameraID: String)
    }

    @MainActor static var handler: ((Action) async -> Void)?

    static func perform(_ action: Action) async {
        guard let handler = await MainActor.run(body: { handler }) else { return }
        await handler(action)
    }
}

struct ToggleMonitorMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mute or Unmute Camera Sound"
    static var isDiscoverable = false

    @Parameter(title: "Camera") var cameraID: String

    init() {}
    init(cameraID: String) { self.cameraID = cameraID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.perform(.toggleMute(cameraID: cameraID))
        return .result()
    }
}

/// Starting talk-back needs the app open (iOS won't start the microphone from the Lock Screen),
/// but stopping it can happen in place.
struct StopTalkingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Talking Through Camera"
    static var isDiscoverable = false

    @Parameter(title: "Camera") var cameraID: String

    init() {}
    init(cameraID: String) { self.cameraID = cameraID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.perform(.stopTalking(cameraID: cameraID))
        return .result()
    }
}

struct StopMonitoringIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Watching Camera"
    static var isDiscoverable = false

    @Parameter(title: "Camera") var cameraID: String

    init() {}
    init(cameraID: String) { self.cameraID = cameraID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.perform(.stopMonitoring(cameraID: cameraID))
        return .result()
    }
}
#endif

// MARK: - Shared formatting (also unit tested)

enum LiveActivityLinks {
    /// Opens the camera's live view; `talk` switches talk-back on once it connects.
    static func live(cameraID: String, talk: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = "mirrormirror"
        components.host = "live"
        components.queryItems = [URLQueryItem(name: "camera", value: cameraID)]
            + (talk ? [URLQueryItem(name: "talk", value: "1")] : [])
        return components.url!
    }

    /// Back to camera mode on the phone that is the camera.
    static let camera = URL(string: "mirrormirror://camera")!

    enum Route: Equatable {
        case live(cameraID: String, talk: Bool)
        case camera
    }

    static func route(for url: URL) -> Route? {
        guard url.scheme == "mirrormirror" else { return nil }
        switch url.host {
        case "camera":
            return .camera
        case "live":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let id = items.first(where: { $0.name == "camera" })?.value, !id.isEmpty else { return nil }
            return .live(cameraID: id, talk: items.contains { $0.name == "talk" && $0.value == "1" })
        default:
            return nil
        }
    }
}

enum LiveActivityFormat {
    /// WebRTC's audio level is linear (room tone ≈ 0.003, speech ≈ 0.1). Map −50…0 dBFS to
    /// 0…1 so a meter moves for ordinary sound, rounded to tenths so updates stay rare.
    static func meterLevel(_ linear: Double?) -> Double {
        guard let linear, linear > 0 else { return 0 }
        let db = 20 * log10(max(linear, 0.000_01))
        let level = min(1, max(0, (db + 50) / 50))
        return (level * 10).rounded() / 10
    }

    static func viewers(_ count: Int, names: [String]) -> String {
        switch count {
        case 0: "No one watching"
        case 1: names.first.map { "\($0) watching" } ?? "1 viewer"
        default: "\(count) viewers"
        }
    }

    static func battery(_ level: Double?) -> String? {
        level.map { "\(Int(($0 * 100).rounded()))%" }
    }
}
