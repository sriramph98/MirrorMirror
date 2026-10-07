import SwiftUI
import MirrorUI

@main
struct MirrorMirrorVisionApp: App {
    @StateObject private var hub = ViewerHub.shared

    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup {
            Text("MirrorMirror for Apple Vision Pro").type(.display)
                .environmentObject(hub)
        }
    }
}
