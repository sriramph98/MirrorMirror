import Foundation

/// Requests that arrive from outside the app's own UI (Live Activity buttons and links) and
/// are carried out by whichever screen owns the thing they act on.
@MainActor
final class AppRoutes: ObservableObject {
    static let shared = AppRoutes()

    /// Switch talk-back on for this camera once its live view is connected.
    @Published var talkCameraID: String?
    /// Close this camera's live view (Stop on the Lock Screen).
    @Published var stopCameraID: String?
    /// Show camera mode (tapping the camera phone's Live Activity after a relaunch).
    @Published var openCameraMode = false

    /// Handles `mirrormirror://live…` and `mirrormirror://camera`. Returns false for other URLs.
    func handle(_ url: URL) -> Bool {
        switch LiveActivityLinks.route(for: url) {
        case let .live(cameraID, talk)?:
            if talk { talkCameraID = cameraID }
            ViewerHub.shared.pendingOpenCameraID = cameraID
            return true
        case .camera?:
            openCameraMode = true
            return true
        case nil:
            return false
        }
    }
}
