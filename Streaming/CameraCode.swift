import CloudKit
import CryptoKit
import Foundation

/// The code on a camera's Pair screen, for adding it from anywhere: while that screen is open
/// the camera leaves its invite, sealed with a key derived from the code, in an iCloud mailbox
/// named by a hash of the code. Typing the code on a viewer finds and opens it.
///
/// Weaker than nearby pairing (the 8-symbol code, about 40 bits, is the only secret), so it
/// only exists while the Pair screen is open and rotates every few minutes.
enum CameraCode {
    static let lifetime: TimeInterval = 5 * 60

    struct Payload: Codable {
        var invite: String
        var sent: Date = Date()
    }

    static func makeCode() -> String { DevicePairing.makeCode() }
    static func formatted(_ code: String) -> String { DevicePairing.formatted(code) }
    static func normalize(_ code: String) -> String { DevicePairing.normalize(code) }
    static func isValid(_ code: String) -> Bool { DevicePairing.isValid(code) }

    private static func key(for code: String) -> PairingKey {
        var hasher = SHA256()
        hasher.update(data: Data("mira-camera-code-v1".utf8))
        hasher.update(data: Data(normalize(code).utf8))
        return PairingKey(cameraID: "camera-code", secret: Data(hasher.finalize()))
    }

    #if DEBUG
    static func sealForTesting(_ invite: PairingInvite, code: String) throws -> Data {
        try key(for: code).seal(Payload(invite: invite.url.absoluteString))
    }
    static func openForTesting(_ data: Data, code: String) throws -> PairingInvite? {
        PairingInvite(string: try key(for: code).open(Payload.self, from: data).invite)
    }
    #endif

    // MARK: Camera

    /// Leaves the sealed invite for `code`. Delete the returned record when the code is retired.
    static func publish(_ invite: PairingInvite, code: String) async throws -> CKRecord.ID {
        let key = key(for: code)
        return try await CloudRelay.shared.post(try key.seal(Payload(invite: invite.url.absoluteString)), to: key.mailbox)
    }

    // MARK: Viewer

    enum LookupError: LocalizedError {
        case badCode, noICloud, notFound

        var errorDescription: String? {
            switch self {
            case .badCode: "Camera codes have 8 letters and numbers."
            case .noICloud: "Sign in to iCloud to add a camera by code, or pick it under Nearby when you're on the same Wi-Fi."
            case .notFound: "No camera is showing that code. Check it, and keep the camera's Pair screen open while you type."
            }
        }
    }

    static func lookUp(_ code: String) async throws -> PairingInvite {
        guard isValid(code) else { throw LookupError.badCode }
        guard await CloudRelay.shared.accountAvailable() else { throw LookupError.noICloud }
        let key = key(for: code)
        // The camera may have published a moment ago; CloudKit queries can lag a little.
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1.5)) }
            let messages = (try? await CloudRelay.shared.fetch(mailbox: key.mailbox, maxAge: lifetime + 60)) ?? []
            for message in messages {
                if let payload = try? key.open(Payload.self, from: message.payload),
                   let invite = PairingInvite(string: payload.invite) {
                    DebugSupport.log("pairing", "found \(invite.name) by code")
                    return invite
                }
            }
        }
        throw LookupError.notFound
    }
}
