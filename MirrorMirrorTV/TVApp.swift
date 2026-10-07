import SwiftUI
import MirrorUI

@main
struct MirrorMirrorTVApp: App {
    @StateObject private var hub = ViewerHub.shared
    @StateObject private var router = TVRouter()

    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(hub)
                .environmentObject(router)
        }
    }
}

/// One screen at a time, the alert banner over all of them. Owns launch-time wiring:
/// `ViewerHub.activate()`, deep links, Top Shelf feed, debug launch arguments.
struct TVRootView: View {
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launched = false

    var body: some View {
        ZStack {
            screen
                .id(screenKey)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            if let alert = router.alert {
                TVAlertBanner(alert: alert) { router.replayAlert() }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, Space.xxl)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(reduceMotion ? nil : Motion.smooth, value: screenKey)
        .animation(reduceMotion ? nil : Motion.smooth, value: router.alert)
        .canvasBackground(Palette.frame)
        .preferredColorScheme(.dark)
        .onOpenURL { router.handle($0, hub: hub) }
        .onAppear(perform: launch)
    }

    @ViewBuilder
    private var screen: some View {
        switch router.screen {
        case .wall: WallView()
        case let .full(cameraID): FullScreenView(cameraID: cameraID)
        case .pair: PairView()
        case .settings: SettingsView()
        }
    }

    /// Full-screen views keep their identity while the camera changes (swipes), so the
    /// transition only runs between kinds of screen.
    private var screenKey: String {
        switch router.screen {
        case .wall: "wall"
        case .full: "full"
        case .pair: "pair"
        case .settings: "settings"
        }
    }

    private func launch() {
        guard !launched else { return }
        launched = true
        hub.activate()
        router.watchEvents(of: hub)
        TopShelfFeed.shared.start(hub: hub)

        #if DEBUG
        TVBonjourProbe.startIfRequested()
        #if targetEnvironment(simulator)
        router.startDebugChannel(hub: hub)
        #endif
        // `-MMForgetCameras`: start from an empty wall (screenshots, pairing tests).
        if ProcessInfo.processInfo.arguments.contains("-MMForgetCameras") { hub.cameras.forEach { hub.remove($0) } }
        if let url = DebugSupport.pairURL, let invite = PairingInvite(string: url) { hub.add(invite) }
        if DebugSupport.autoWatch, let camera = hub.cameras.last { router.open(camera) }
        switch TVDebug.screen {
        case "full", "timeline", "events":
            if let camera = hub.cameras.first { router.open(camera) }
        case "pair": router.screen = .pair
        case "settings": router.screen = .settings
        default: break
        }
        #endif
    }
}
