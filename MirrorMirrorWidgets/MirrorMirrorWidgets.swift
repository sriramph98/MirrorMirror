import SwiftUI
import WidgetKit
import MirrorUI

/// Live Activities only: the app has no Home Screen widgets.
@main
struct MirrorMirrorWidgets: WidgetBundle {
    init() {
        _ = Fonts.register()
    }

    var body: some Widget {
        MonitorLiveActivity()
        CameraLiveActivity()
    }
}
