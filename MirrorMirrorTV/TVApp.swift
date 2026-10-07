import SwiftUI
import MirrorUI

@main
struct MirrorMirrorTVApp: App {
    @StateObject private var hub = ViewerHub.shared

    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup {
            Text("MirrorMirror for Apple TV").type(.display)
                .environmentObject(hub)
                .canvasBackground()
        }
    }
}
