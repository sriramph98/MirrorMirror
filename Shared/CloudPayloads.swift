import Foundation

/// Sealed into the CloudKit presence record every couple of minutes.
struct PresenceInfo: Codable {
    var name: String
    var batteryLevel: Double?
    var isCharging: Bool
    var isRecording: Bool
    var viewerCount: Int
    var updated: Date
}

/// Sealed into the CloudKit event record that triggers viewer push notifications.
struct CloudEventInfo: Codable {
    var event: CameraEvent
    var cameraName: String
}

/// CloudKit record field carrying the sealed `CloudEventInfo` as base64 text, so it can ride
/// inside the push itself (push payloads can include string fields).
let sealedEventField = "sealedText"

/// The pairing keys the notification extension needs to decrypt event pushes, mirrored by the
/// app into a keychain access group the extension can read.
enum NotificationKeyStore {
    struct Entry: Codable {
        var key: PairingKey
        var cameraName: String
    }

    private static let account = "notification-camera-keys"

    /// `$(AppIdentifierPrefix)com.sriramph.mirrormirror.shared`, expanded into each Info.plist at build time.
    static var accessGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MMKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Keyed by CloudKit subscription ID (`ev-<camera id>`).
    static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        Keychain.set(data, for: account, accessGroup: accessGroup)
    }

    static func load() -> [String: Entry] {
        Keychain.data(for: account, accessGroup: accessGroup)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
}

extension EventKind {
    /// Events worth breaking through Focus for.
    var isUrgent: Bool {
        switch self {
        case .crying, .glassBreak, .alarm, .person, .overheating: true
        default: false
        }
    }
}
