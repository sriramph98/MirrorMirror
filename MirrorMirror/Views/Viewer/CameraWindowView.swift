import SwiftUI
import MirrorUI

/// A camera in its own window (Mac, and iPad with multiple windows). The hub keeps the
/// connection; the live view only shows it. Audio follows whichever window is key.
struct CameraWindowView: View {
    let cameraID: String?
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.commandRouter) private var router

    var body: some View {
        Group {
            if let cameraID, let camera = hub.camera(id: cameraID) {
                LiveView(connection: hub.connection(for: camera), ownsConnection: false, onClose: nil)
                    .background(WindowSceneConfigurator(minimumSize: CGSize(width: 640, height: 440), title: camera.name))
                    .onAppear {
                        CameraWindows.open.insert(cameraID)
                        hub.connection(for: camera).connect()
                        router?.openInNewWindow = nil
                    }
                    .onDisappear {
                        CameraWindows.open.remove(cameraID)
                        // The main window may still be showing this camera; leave it alone then.
                        if CameraWindows.primaryShowing != cameraID {
                            hub.connection(for: camera).disconnect()
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { hub.audioFocus = cameraID }
                    }
            } else {
                EmptyState(symbol: "video.slash", title: "Camera removed",
                           message: "This camera is no longer paired with this device. Close the window.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground(Palette.frame)
            }
        }
        .preferredColorScheme(.dark)
    }
}
