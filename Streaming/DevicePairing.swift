import CryptoKit
import Foundation

/// Pairing for devices with no camera to scan a QR code and no keyboard worth typing a link
/// on (Apple TV, Vision Pro). The new device shows a short code; on an iPhone or iPad that
/// already has the cameras you enter the code, and the camera list travels sealed through the
/// iCloud mailbox derived from it. Devices on the same Apple Account don't need this: they pick
/// cameras up through iCloud key-value storage automatically.
enum DevicePairing {
    /// Letters and digits that can't be confused with each other on a TV screen.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let codeLength = 8
    /// How long a code stays valid on the device that shows it.
    static let codeLifetime: TimeInterval = 10 * 60

    struct Payload: Codable {
        var cameras: [PairedCamera]
        var fromDevice: String
        var sent: Date = Date()
    }

    static func makeCode() -> String {
        String((0..<codeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// "ABCD2345" → "ABCD-2345" for display.
    static func formatted(_ code: String) -> String {
        let c = normalize(code)
        guard c.count == codeLength else { return c }
        return String(c.prefix(4)) + "-" + String(c.suffix(4))
    }

    /// Accepts what a person types: case, spaces and dashes don't matter; 0/O and 1/I are mapped.
    static func normalize(_ input: String) -> String {
        String(input.uppercased().compactMap { ch -> Character? in
            switch ch {
            case "0": return "O"
            case "1", "I": return "L"
            case " ", "-", "_": return nil
            default: return alphabet.contains(ch) ? ch : nil
            }
        })
    }

    static func isValid(_ code: String) -> Bool { normalize(code).count == codeLength }

    /// The code is low-entropy by design (8 symbols ≈ 40 bits), so the mailbox lives only while
    /// the device waits and the payload carries nothing readable without the code.
    private static func key(for code: String) -> PairingKey {
        var hasher = SHA256()
        hasher.update(data: Data("mirrormirror-device-pairing-v1".utf8))
        hasher.update(data: Data(normalize(code).utf8))
        return PairingKey(cameraID: "device-pairing", secret: Data(hasher.finalize()))
    }

    #if DEBUG
    static func sealForTesting(_ payload: Payload, code: String) throws -> Data { try key(for: code).seal(payload) }
    static func openForTesting(_ data: Data, code: String) throws -> Payload { try key(for: code).open(Payload.self, from: data) }
    #endif

    // MARK: Sending (iPhone / iPad / Mac that already has the cameras)

    enum SendError: LocalizedError {
        case badCode, noCameras, noICloud
        var errorDescription: String? {
            switch self {
            case .badCode: "That code isn't complete. It has 8 letters and numbers."
            case .noCameras: "There are no cameras on this device to share."
            case .noICloud: "Sign in to iCloud to pair another device."
            }
        }
    }

    static func send(_ cameras: [PairedCamera], code: String) async throws {
        guard isValid(code) else { throw SendError.badCode }
        guard !cameras.isEmpty else { throw SendError.noCameras }
        guard await CloudRelay.shared.accountAvailable() else { throw SendError.noICloud }
        let key = key(for: code)
        let payload = Payload(cameras: cameras, fromDevice: DeviceIdentity.name)
        _ = try await CloudRelay.shared.post(try key.seal(payload), to: key.mailbox)
        DebugSupport.log("pairing", "sent \(cameras.count) camera(s) for code \(formatted(code))")
    }

    // MARK: Receiving (Apple TV / Vision Pro showing the code)

    /// Polls the code's mailbox until a camera list arrives or the code expires. Returns nil on
    /// expiry or if iCloud isn't available. Cancel the task to stop early.
    static func receive(code: String) async -> Payload? {
        guard await CloudRelay.shared.accountAvailable() else { return nil }
        let key = key(for: code)
        let deadline = Date().addingTimeInterval(codeLifetime)
        while Date() < deadline, !Task.isCancelled {
            if let messages = try? await CloudRelay.shared.fetch(mailbox: key.mailbox, maxAge: codeLifetime) {
                for message in messages {
                    if let payload = try? key.open(Payload.self, from: message.payload) {
                        await CloudRelay.shared.delete([message.id])
                        DebugSupport.log("pairing", "received \(payload.cameras.count) camera(s) from \(payload.fromDevice)")
                        return payload
                    }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }
}
