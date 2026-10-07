import Foundation

/// A camera this device can watch.
struct PairedCamera: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case invite, iCloud }

    var key: PairingKey
    var name: String
    var source: Source
    var addedAt: Date = Date()
    var notificationsEnabled = true

    var id: String { key.cameraID }
    var subscriptionID: String { "ev-" + key.cameraID }
}

/// Same-Apple-Account pairing through iCloud key-value storage: a camera writes its invite,
/// every other device signed into that account sees it and adds the camera automatically.
enum ICloudPairing {
    private static let prefix = "camera."
    private static var store: NSUbiquitousKeyValueStore? {
        Entitlements.hasKeyValueStore ? NSUbiquitousKeyValueStore.default : nil
    }

    static func publish(_ invite: PairingInvite) {
        guard let store else { return }
        store.set(invite.url.absoluteString, forKey: prefix + invite.key.cameraID)
        store.synchronize()
    }

    static func invites() -> [PairingInvite] {
        guard let store else { return [] }
        store.synchronize()
        return store.dictionaryRepresentation.compactMap { key, value in
            guard key.hasPrefix(prefix), let string = value as? String else { return nil }
            return PairingInvite(string: string)
        }
    }

    static func observe(_ handler: @escaping () -> Void) -> NSObjectProtocol? {
        guard let store else { return nil }
        return NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                      object: store, queue: .main) { _ in handler() }
    }
}

extension Entitlements {
    static let hasKeyValueStore: Bool = hasCloudKit
}
