import SwiftUI
import MirrorUI

/// MirrorMirror for Apple Vision Pro: windows you place around the room.
///
/// - `cameras`: the camera browser (one window).
/// - `camera`: one window per camera, opened with `openWindow(id: "camera", value: cameraID)`.
///   Each keeps its own connection alive while open; the most recently touched one has audio focus.
@main
struct MirrorMirrorVisionApp: App {
    @StateObject private var hub = ViewerHub.shared
    @StateObject private var session = VisionSession.shared

    init() {
        Fonts.register()
        VisionSession.shared.applyLaunchArguments()
    }

    var body: some Scene {
        WindowGroup(id: "cameras") {
            CameraBrowserWindow()
                .environmentObject(hub)
                .environmentObject(session)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)

        WindowGroup(id: "camera", for: String.self) { $cameraID in
            CameraWindow(cameraID: cameraID ?? "")
                .environmentObject(hub)
                .environmentObject(session)
        }
        .defaultSize(width: 960, height: 540)
        .windowResizability(.contentMinSize)
    }
}
