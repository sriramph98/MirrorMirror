import CryptoKit
import Foundation
import Network

/// Adding a camera that's on the same network: the viewer picks it from a list, the camera
/// shows a one-time 6-digit code, the person types it on the viewer, and the camera's pairing
/// key travels encrypted to the viewer.
///
/// The code never crosses the network. Each side masks a fresh X25519 public key with a pad
/// derived from the code (encrypted key exchange), so:
/// - someone listening on the Wi-Fi sees two random-looking keys and can't test code guesses
///   offline (any guess unmasks to *some* key, and they hold neither private key);
/// - someone in the middle gets exactly one online guess, after which the camera ends the
///   attempt and the next one uses a new code;
/// - the viewer proves it derived the same session key (it knew the code) before the camera
///   sends anything secret, and the invite is sealed with that key.
enum NearbyPairing {
    static let serviceType = "_mirror-pair._tcp"
    static let codeLength = 6
    /// How long the camera waits for the code to be typed.
    static let codeLifetime: TimeInterval = 120

    /// What travels over the pairing connection (length-prefixed JSON frames).
    enum Message: Codable {
        case hello(viewerID: String, viewerName: String, nonce: Data)
        case ready(cameraName: String, cameraID: String, nonce: Data)
        case declined(reason: String)
        case viewerKey(Data)
        case cameraKey(Data)
        case proof(Data)
        case invite(sealed: Data)
        case wrongCode
    }

    struct Payload: Codable {
        var invite: String
    }

    // MARK: Crypto (pure, unit tested)

    static func makeCode() -> String {
        String((0..<codeLength).map { _ in Character(String(Int.random(in: 0...9))) })
    }

    /// "482913" → "482 913".
    static func formatted(_ code: String) -> String {
        let digits = normalize(code)
        guard digits.count == codeLength else { return digits }
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    static func normalize(_ input: String) -> String { input.filter(\.isASCII).filter(\.isNumber) }

    static func makeNonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    enum Role: String { case viewer, camera }

    /// 32 bytes that hide one side's public key. Different for each side and each attempt.
    static func pad(code: String, role: Role, viewerNonce: Data, cameraNonce: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalize(code).utf8)),
                                         salt: viewerNonce + cameraNonce,
                                         info: Data("mira-nearby-v1-pad-\(role.rawValue)".utf8),
                                         outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// X25519 public keys always have the top bit clear; randomise it so a wrong-code unmask
    /// can't be told apart by that bit, then XOR with the pad.
    static func mask(_ publicKey: Data, pad: Data) -> Data {
        var bytes = [UInt8](publicKey)
        bytes[31] |= UInt8.random(in: 0...1) << 7
        return Data(zip(bytes, pad).map { $0 ^ $1 })
    }

    static func unmask(_ masked: Data, pad: Data) -> Data {
        var bytes = zip(masked, pad).map { $0 ^ $1 }
        bytes[31] &= 0x7F
        return Data(bytes)
    }

    static func sessionKey(_ secret: SharedSecret, viewerNonce: Data, cameraNonce: Data,
                           viewerMasked: Data, cameraMasked: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: viewerNonce + cameraNonce,
                                       sharedInfo: Data("mira-nearby-v1-session".utf8) + viewerMasked + cameraMasked,
                                       outputByteCount: 32)
    }

    static func viewerProof(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("mira-nearby-v1-viewer-proof".utf8), using: key))
    }

    static func isValidProof(_ proof: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("mira-nearby-v1-viewer-proof".utf8), using: key)
    }

    // MARK: Framing

    static func send(_ message: Message, on connection: NWConnection) async throws {
        try await Framing.send(try JSONEncoder().encode(message), on: connection)
    }

    static func receive(on connection: NWConnection, timeout: TimeInterval) async throws -> Message {
        try await withTimeout(timeout) {
            try await withTaskCancellationHandler {
                try JSONDecoder().decode(Message.self, from: try await Framing.receive(on: connection))
            } onCancel: {
                connection.cancel()
            }
        }
    }
}

enum NearbyPairingError: LocalizedError, Equatable {
    case unreachable
    case busy
    case declined(String)
    case wrongCode
    case broken

    var errorDescription: String? {
        switch self {
        case .unreachable: "Couldn't reach that camera. Make sure camera mode is still open on it."
        case .busy: "That camera is pairing with another device. Try again in a moment."
        case let .declined(reason): reason
        case .wrongCode: "That isn't the code on the camera. Tap the camera to get a new code and try again."
        case .broken: "Pairing didn't complete. Try again."
        }
    }
}

// MARK: - Viewer side

/// A camera in camera mode on this network that can be added with a code.
struct NearbyCamera: Identifiable, Hashable {
    var id: String          // camera ID (not secret; the pairing key is)
    var name: String
    var endpoint: NWEndpoint
}

/// Lists cameras offering nearby pairing.
@MainActor
final class NearbyCameraBrowser: ObservableObject {
    @Published private(set) var cameras: [NearbyCamera] = []
    @Published private(set) var isBrowsing = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyPairing.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [NearbyCamera] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var id = name
                if case let .bonjour(txt) = result.metadata, let value = txt["id"] { id = value }
                return NearbyCamera(id: id, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.cameras = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        cameras = []
        isBrowsing = false
    }
}

/// One pairing attempt from the viewer: `begin` asks the camera to show a code, `complete`
/// sends the key exchange for the code the person typed and returns the camera's invite.
final class NearbyPairingSession: @unchecked Sendable {
    let cameraName: String
    private let connection: NWConnection
    private let viewerNonce: Data
    private let cameraNonce: Data

    private init(connection: NWConnection, cameraName: String, viewerNonce: Data, cameraNonce: Data) {
        self.connection = connection
        self.cameraName = cameraName
        self.viewerNonce = viewerNonce
        self.cameraNonce = cameraNonce
    }

    static func begin(with camera: NearbyCamera) async throws -> NearbyPairingSession {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: camera.endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
            if case .waiting = state { connection.cancel() }
        }
        connection.start(queue: DispatchQueue(label: "mira.nearby-pairing"))
        let nonce = NearbyPairing.makeNonce()
        do {
            try await NearbyPairing.send(.hello(viewerID: DeviceIdentity.id, viewerName: DeviceIdentity.name, nonce: nonce), on: connection)
            switch try await NearbyPairing.receive(on: connection, timeout: 10) {
            case let .ready(cameraName, _, cameraNonce):
                DebugSupport.log("pairing", "\(cameraName) is showing a code")
                return NearbyPairingSession(connection: connection, cameraName: cameraName, viewerNonce: nonce, cameraNonce: cameraNonce)
            case let .declined(reason):
                connection.cancel()
                throw reason == "busy" ? NearbyPairingError.busy : NearbyPairingError.declined(reason)
            default:
                connection.cancel()
                throw NearbyPairingError.broken
            }
        } catch let error as NearbyPairingError {
            throw error
        } catch {
            connection.cancel()
            throw NearbyPairingError.unreachable
        }
    }

    func complete(code: String) async throws -> PairingInvite {
        defer { connection.cancel() }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let viewerMasked = NearbyPairing.mask(privateKey.publicKey.rawRepresentation,
                                              pad: NearbyPairing.pad(code: code, role: .viewer, viewerNonce: viewerNonce, cameraNonce: cameraNonce))
        do {
            try await NearbyPairing.send(.viewerKey(viewerMasked), on: connection)
            guard case let .cameraKey(cameraMasked) = try await NearbyPairing.receive(on: connection, timeout: 15) else {
                throw NearbyPairingError.broken
            }
            let cameraPublic = NearbyPairing.unmask(cameraMasked,
                                                    pad: NearbyPairing.pad(code: code, role: .camera, viewerNonce: viewerNonce, cameraNonce: cameraNonce))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: cameraPublic))
            let key = NearbyPairing.sessionKey(secret, viewerNonce: viewerNonce, cameraNonce: cameraNonce,
                                               viewerMasked: viewerMasked, cameraMasked: cameraMasked)
            try await NearbyPairing.send(.proof(NearbyPairing.viewerProof(key)), on: connection)
            switch try await NearbyPairing.receive(on: connection, timeout: 15) {
            case let .invite(sealed):
                let payload = try JSONDecoder().decode(NearbyPairing.Payload.self,
                                                       from: try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key))
                guard let invite = PairingInvite(string: payload.invite) else { throw NearbyPairingError.broken }
                DebugSupport.log("pairing", "paired with \(invite.name) nearby")
                return invite
            case .wrongCode:
                throw NearbyPairingError.wrongCode
            case let .declined(reason):
                throw NearbyPairingError.declined(reason)
            default:
                throw NearbyPairingError.broken
            }
        } catch let error as NearbyPairingError {
            throw error
        } catch {
            // The camera answers a wrong code with `.wrongCode`; anything else is the network.
            throw NearbyPairingError.broken
        }
    }

    func cancel() { connection.cancel() }
}
