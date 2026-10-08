import CryptoKit
import Foundation
import Network

/// The camera's half of `NearbyPairing`: advertises this camera by name on the local network,
/// shows a one-time code when a viewer asks to pair, and hands over the invite only to a viewer
/// that proves it typed that code. One attempt at a time; a wrong code ends the attempt and
/// briefly pauses new ones.
@MainActor
final class NearbyPairingServer: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let viewerName: String
        let code: String
        let expires: Date
    }

    enum Outcome: Equatable {
        case paired(viewerName: String)
        case wrongCode(viewerName: String)
    }

    /// The code on screen right now (camera mode shows it over everything).
    @Published private(set) var request: Request?
    /// The last attempt's result, for a toast.
    @Published private(set) var outcome: Outcome?

    /// Provided by the camera: the current invite (it changes when the pairing code is reset).
    var invite: () -> PairingInvite = { fatalError("NearbyPairingServer.invite not set") }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mira.nearby-pairing-server")
    private var active: NWConnection?
    private var pausedUntil = Date.distantPast
    private var advertisedName = ""
    private var cameraID = ""

    func start(name: String, cameraID: String) {
        stop()
        advertisedName = name
        self.cameraID = cameraID
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            // Bonjour names are limited to 63 bytes; it adds " (2)" itself if two cameras share one.
            listener.service = NWListener.Service(name: String(name.utf8.prefix(60)) ?? "Camera",
                                                  type: NearbyPairing.serviceType,
                                                  txtRecord: NWTXTRecord(["id": cameraID]))
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, self.listener != nil else { return }
                        self.start(name: self.advertisedName, cameraID: self.cameraID)
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DebugSupport.log("pairing", "nearby listener failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endAttempt()
    }

    /// The camera was renamed: advertise the new name.
    func rename(_ name: String) {
        guard listener != nil, name != advertisedName else { return }
        start(name: name, cameraID: cameraID)
    }

    /// The person at the camera tapped Decline.
    func decline() {
        guard let connection = active else { return }
        Task { try? await NearbyPairing.send(.declined(reason: "The camera's owner declined."), on: connection) }
        endAttempt()
    }

    func clearOutcome() { outcome = nil }

    private func endAttempt() {
        active?.cancel()
        active = nil
        request = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { await run(connection) }
    }

    private func run(_ connection: NWConnection) async {
        guard case let .hello(viewerID, viewerName, viewerNonce)? = try? await NearbyPairing.receive(on: connection, timeout: 10),
              viewerNonce.count == 16 else {
            connection.cancel()
            return
        }
        guard active == nil, Date() >= pausedUntil else {
            try? await NearbyPairing.send(.declined(reason: "busy"), on: connection)
            connection.cancel()
            return
        }
        let code = NearbyPairing.makeCode()
        let cameraNonce = NearbyPairing.makeNonce()
        active = connection
        request = Request(viewerName: viewerName, code: code, expires: Date().addingTimeInterval(NearbyPairing.codeLifetime))
        DebugSupport.log("pairing", "\(viewerName) asked to pair; showing a code")
        #if DEBUG
        DebugSupport.log("pairing", "code \(code)")   // lets a Mac-driven test type it on the viewer
        #endif

        do {
            try await NearbyPairing.send(.ready(cameraName: advertisedName, cameraID: cameraID, nonce: cameraNonce), on: connection)
            guard case let .viewerKey(viewerMasked) = try await NearbyPairing.receive(on: connection, timeout: NearbyPairing.codeLifetime),
                  viewerMasked.count == 32 else { throw NearbyPairingError.broken }

            let viewerPublic = NearbyPairing.unmask(viewerMasked, pad: NearbyPairing.pad(code: code, role: .viewer,
                                                                                         viewerNonce: viewerNonce, cameraNonce: cameraNonce))
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let cameraMasked = NearbyPairing.mask(privateKey.publicKey.rawRepresentation,
                                                  pad: NearbyPairing.pad(code: code, role: .camera, viewerNonce: viewerNonce, cameraNonce: cameraNonce))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: viewerPublic))
            let key = NearbyPairing.sessionKey(secret, viewerNonce: viewerNonce, cameraNonce: cameraNonce,
                                               viewerMasked: viewerMasked, cameraMasked: cameraMasked)
            try await NearbyPairing.send(.cameraKey(cameraMasked), on: connection)

            guard case let .proof(proof) = try await NearbyPairing.receive(on: connection, timeout: 15) else {
                throw NearbyPairingError.broken
            }
            guard NearbyPairing.isValidProof(proof, key: key) else {
                DebugSupport.log("pairing", "wrong code from \(viewerName)")
                try? await NearbyPairing.send(.wrongCode, on: connection)
                pausedUntil = Date().addingTimeInterval(5)
                outcome = .wrongCode(viewerName: viewerName)
                finish(connection)
                return
            }
            let payload = try JSONEncoder().encode(NearbyPairing.Payload(invite: invite().url.absoluteString))
            let sealed = try AES.GCM.seal(payload, using: key).combined ?? Data()
            try await NearbyPairing.send(.invite(sealed: sealed), on: connection)
            DebugSupport.log("pairing", "paired \(viewerName) (\(viewerID.prefix(8)))")
            outcome = .paired(viewerName: viewerName)
            try? await Task.sleep(for: .milliseconds(300))
        } catch {
            DebugSupport.log("pairing", "attempt from \(viewerName) ended: \(error)")
        }
        finish(connection)
    }

    /// Ends this attempt unless a newer one has already replaced it (after Decline).
    private func finish(_ connection: NWConnection) {
        connection.cancel()
        if active === connection { endAttempt() }
    }
}
