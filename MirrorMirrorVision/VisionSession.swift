import SwiftUI
import Combine
import OSLog
import MirrorUI

/// `print` from a visionOS simulator app doesn't reach `simctl launch --console`, so the Vision
/// target logs through OSLog instead; read it with `log show --predicate 'subsystem == …vision'`.
enum VisionLog {
    static let logger = Logger(subsystem: "com.sriramph.mirrormirror.vision", category: "vision")

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.notice("MM vision: \(text, privacy: .public)")
        DebugSupport.log("vision", text)
        #endif
    }
}

/// Which windows are open, so each camera's connection lives exactly as long as something shows
/// its picture (the browser's thumbnail grid or that camera's own window). Also carries the
/// debug launch arguments that open a screen for screenshots.
@MainActor
final class VisionSession: ObservableObject {
    static let shared = VisionSession()

    @Published private(set) var openCameraWindows: Set<String> = []
    @Published var browserVisible = false

    /// Debug screens: `-MMScreen <browser|camera|pair|settings|gallery>`.
    enum LaunchScreen: String { case browser, camera, pair, settings, gallery }
    private(set) var launchScreen: LaunchScreen?
    /// `-MMAutoWatch`: open the most recently added camera's window at launch.
    private(set) var autoWatch = false
    /// `-MMShowTimeline` / `-MMShowControls` / `-MMShowExport`: open the camera window with that panel showing.
    private(set) var showTimelineAtLaunch = false
    private(set) var showControlsAtLaunch = false
    private(set) var showExportAtLaunch = false
    private var launchHandled = false
    private var cancellables = Set<AnyCancellable>()
    private var observedConnections: Set<String> = []

    private init() {
        #if DEBUG
        ViewerHub.shared.lan.$visibleMailboxes
            .removeDuplicates()
            .sink { boxes in VisionLog.log("bonjour sees \(boxes.count) camera(s)") }
            .store(in: &cancellables)
        #endif
    }

    func applyLaunchArguments() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = UserDefaults.standard.string(forKey: "MMScreen") {
            launchScreen = LaunchScreen(rawValue: raw.lowercased())
        }
        if DebugSupport.showGallery { launchScreen = .gallery }
        autoWatch = DebugSupport.autoWatch || launchScreen == .camera
        showTimelineAtLaunch = arguments.contains("-MMShowTimeline")
        showControlsAtLaunch = arguments.contains("-MMShowControls")
        showExportAtLaunch = arguments.contains("-MMShowExport")
        if let string = DebugSupport.pairURL, let invite = PairingInvite(string: string) {
            ViewerHub.shared.add(invite)
            VisionLog.log("paired \(invite.name) from launch argument")
        }
        #endif
    }

    /// Runs once, from the browser window's first appearance.
    func takeLaunchActions() -> (screen: LaunchScreen?, autoWatch: Bool) {
        guard !launchHandled else { return (nil, false) }
        launchHandled = true
        return (launchScreen, autoWatch)
    }

    // MARK: Windows

    func windowOpened(_ cameraID: String) {
        openCameraWindows.insert(cameraID)
        reconcile()
    }

    func windowClosed(_ cameraID: String) {
        openCameraWindows.remove(cameraID)
        reconcile()
    }

    /// Connects cameras something is showing and disconnects the rest.
    func reconcile() {
        let hub = ViewerHub.shared
        for camera in hub.cameras {
            let wanted = browserVisible || openCameraWindows.contains(camera.id)
            let connection = hub.connection(for: camera)
            observe(connection)
            if wanted {
                if connection.phase == .idle {
                    VisionLog.log("connect \(camera.name)")
                    connection.connect()
                }
            } else if connection.phase != .idle {
                VisionLog.log("disconnect \(camera.name)")
                connection.disconnect()
            }
        }
    }

    private func observe(_ connection: CameraConnection) {
        #if DEBUG
        guard observedConnections.insert(connection.id).inserted else { return }
        let name = connection.camera.name
        connection.$phase.removeDuplicates()
            .sink { phase in VisionLog.log("\(name): \(phase)") }
            .store(in: &cancellables)
        connection.$hasVideo.removeDuplicates()
            .sink { has in VisionLog.log("\(name): video \(has ? "flowing" : "stopped")") }
            .store(in: &cancellables)
        #endif
    }

    // MARK: Deep links

    /// `mirrormirror://pair?...` adds the camera; `mirrormirror://camera/<id>` opens its window.
    func handle(_ url: URL, openWindow: OpenWindowAction) {
        let hub = ViewerHub.shared
        if let invite = PairingInvite(string: url.absoluteString) {
            let camera = hub.add(invite)
            openWindow(id: "camera", value: camera.id)
            return
        }
        guard url.scheme == "mirrormirror", url.host == "camera" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        if hub.camera(id: id) != nil { openWindow(id: "camera", value: id) }
    }
}

// MARK: - visionOS helpers

extension View {
    /// Hover highlight shaped like MirrorUI's round tool buttons.
    func toolHover() -> some View {
        contentShape(.hoverEffect, .circle).hoverEffect()
    }

    /// Hover highlight for pills and chips.
    func pillHover() -> some View {
        contentShape(.hoverEffect, .capsule).hoverEffect()
    }

    /// Hover highlight for cards and rows.
    func cardHover(_ radius: CGFloat = Radius.panel) -> some View {
        contentShape(.hoverEffect, .rect(cornerRadius: radius, style: .continuous)).hoverEffect()
    }
}

/// visionOS HIG: 60 pt minimum targets.
enum VisionSize {
    static let tool: CGFloat = 60
    static let toolSmall: CGFloat = 52
    static let timelineWidth: CGFloat = 400
    /// The timeline panel stands taller than a 16:9 window so the strip, playback row and a few
    /// events fit without scrolling.
    static let timelineMinHeight: CGFloat = 620
}
