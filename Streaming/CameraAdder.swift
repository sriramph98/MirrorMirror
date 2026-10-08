import Foundation

/// The "add a camera by code" flows for viewers that draw their own UI (Apple TV, Vision Pro):
/// pick a camera on this network and type the one-time code it shows, or type the code from a
/// camera's Pair screen (works from anywhere through iCloud). Hands back the camera's invite.
@MainActor
final class CameraAdder: ObservableObject {
    enum Stage: Equatable {
        case idle
        case reaching(cameraID: String)
        /// The camera is showing a code; the person types it.
        case nearbyCode(cameraName: String)
        case checking
        /// Typing the code from a camera's Pair screen.
        case cameraCode
        case lookingUp
    }

    @Published private(set) var stage: Stage = .idle
    @Published var error: String?
    /// What's typed for a nearby camera (6 digits) or a camera code (8 symbols).
    @Published var typed = ""

    let nearby = NearbyCameraBrowser()
    private var session: NearbyPairingSession?
    /// Called with the camera's invite once a code checks out.
    var onInvite: (PairingInvite) -> Void = { _ in }

    /// Nearby cameras other than this device's own.
    var nearbyCameras: [NearbyCamera] { nearby.cameras.filter { $0.id != DeviceIdentity.id } }

    var canSubmit: Bool {
        switch stage {
        case .nearbyCode: NearbyPairing.normalize(typed).count == NearbyPairing.codeLength
        case .cameraCode: CameraCode.isValid(typed)
        default: false
        }
    }

    func start() { nearby.start() }

    func stop() {
        nearby.stop()
        cancel()
    }

    func pick(_ camera: NearbyCamera) {
        guard stage == .idle else { return }
        error = nil
        typed = ""
        stage = .reaching(cameraID: camera.id)
        Task {
            do {
                let session = try await NearbyPairingSession.begin(with: camera)
                self.session = session
                stage = .nearbyCode(cameraName: session.cameraName)
            } catch {
                self.error = error.localizedDescription
                stage = .idle
            }
        }
    }

    func enterCameraCode() {
        error = nil
        typed = ""
        stage = .cameraCode
    }

    func submit() {
        guard canSubmit else { return }
        error = nil
        let code = typed
        switch stage {
        case .nearbyCode:
            guard let session else { return }
            stage = .checking
            Task {
                do {
                    let invite = try await session.complete(code: code)
                    finish(invite)
                } catch {
                    // Every attempt uses a new code: go back to the list.
                    self.error = error.localizedDescription
                    self.session = nil
                    stage = .idle
                }
            }
        case .cameraCode:
            stage = .lookingUp
            Task {
                do {
                    finish(try await CameraCode.lookUp(code))
                } catch {
                    self.error = error.localizedDescription
                    stage = .cameraCode
                }
            }
        default:
            break
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        typed = ""
        stage = .idle
    }

    private func finish(_ invite: PairingInvite) {
        session = nil
        typed = ""
        stage = .idle
        onInvite(invite)
    }
}
