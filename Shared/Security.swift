import Foundation
import CryptoKit
import Security
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

// MARK: - Keychain

enum Keychain {
    private static let service = "sriramph.MirrorMirror"

    static func data(for key: String, accessGroup: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for key: String, accessGroup: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        // AfterFirstUnlock so a camera left running behind a locked screen can still read its keys.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func setCodable<T: Encodable>(_ value: T, for key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, for: key) }
    }
}

// MARK: - This device

enum DeviceIdentity {
    /// Stable per-install identifier for this device.
    static let id: String = {
        if let data = Keychain.data(for: "device-id"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        Keychain.set(Data(id.utf8), for: "device-id")
        return id
    }()

    static var name: String {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #elseif targetEnvironment(macCatalyst)
        // UIDevice reports the iPad idiom's model name on Mac; use the computer's host name instead.
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "").replacingOccurrences(of: "-", with: " ")
        return host.isEmpty ? "Mac (\(String(id.prefix(4))))" : host
        #else
        let name = UIDevice.current.name
        // iOS 16+ returns the generic model name without the entitlement; make it a little friendlier.
        return name == UIDevice.current.model ? "\(name) (\(String(id.prefix(4))))" : name
        #endif
    }
}

// MARK: - Pairing keys

/// The secret a camera hands out (QR code, link, or iCloud). Everything that crosses a
/// network or CloudKit is derived from it: the Bonjour/CloudKit mailbox names are
/// one-way hashes and every signaling payload is sealed with AES-GCM.
struct PairingKey: Codable, Hashable {
    var cameraID: String
    var secret: Data

    static func generate(cameraID: String) -> PairingKey {
        PairingKey(cameraID: cameraID, secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func digest(_ label: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(label.utf8))
        hasher.update(data: secret)
        hasher.update(data: Data(cameraID.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Opaque name a camera listens on (Bonjour service name, CloudKit inbox).
    var mailbox: String { String(digest("mailbox").prefix(32)) }
    /// CloudKit mailbox camera events are posted to (viewers subscribe for push).
    var eventMailbox: String { String(digest("events").prefix(32)) }
    /// CloudKit record name for the camera's presence heartbeat.
    var presenceRecordName: String { "p-" + String(digest("presence").prefix(32)) }
    /// CloudKit record name for the latest sealed snapshot (Apple Watch fallback when the iPhone isn't near).
    var snapshotRecordName: String { "s-" + String(digest("snapshot").prefix(32)) }

    func replyMailbox(session: UUID) -> String {
        String(digest("reply-" + session.uuidString).prefix(32))
    }

    private var symmetricKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data(cameraID.utf8),
                               info: Data("mirrormirror-signal-v1".utf8),
                               outputByteCount: 32)
    }

    func seal<T: Encodable>(_ value: T) throws -> Data {
        let plain = try JSONEncoder().encode(value)
        return try AES.GCM.seal(plain, using: symmetricKey).combined!
    }

    func open<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let box = try AES.GCM.SealedBox(combined: data)
        return try JSONDecoder().decode(T.self, from: AES.GCM.open(box, using: symmetricKey))
    }
}

// MARK: - Pairing links

/// `mirrormirror://pair?v=1&id=<camera id>&n=<name>&k=<base64url secret>`, shown as a QR code
/// and shareable as a link (AirDrop, Messages) for family members on other Apple Accounts.
struct PairingInvite: Hashable {
    var key: PairingKey
    var name: String

    var url: URL {
        var c = URLComponents()
        c.scheme = "mirrormirror"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: key.cameraID),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "k", value: key.secret.base64URLEncoded),
        ]
        return c.url!
    }

    init(key: PairingKey, name: String) {
        self.key = key
        self.name = name
    }

    init?(string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "mirrormirror", c.host == "pair",
              let items = c.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              let k = items.first(where: { $0.name == "k" })?.value,
              let secret = Data(base64URLEncoded: k), secret.count == 32
        else { return nil }
        self.key = PairingKey(cameraID: id, secret: secret)
        self.name = items.first(where: { $0.name == "n" })?.value ?? "Camera"
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
