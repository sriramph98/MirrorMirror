import Combine
import UIKit
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// The camera phone's Live Activity: recording, viewers, battery and heat, and a warning when
/// iOS pauses the camera because the app left the screen. Runs for as long as camera mode does.
@MainActor
final class CameraActivityController {
    static let shared = CameraActivityController()

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private let session = LiveActivitySession<CameraActivityAttributes>(name: "camera")
    private weak var host: CameraHost?
    private var observer: AnyCancellable?
    private var isPaused = false
    private var startedAt = Date()

    func attach(_ host: CameraHost) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        session.reset()
        self.host = host
        isPaused = false
        startedAt = Date()
        // The host publishes meter levels many times a second; the state below leaves them
        // out, so those changes compare equal and never reach ActivityKit.
        observer = host.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    func detach() {
        observer = nil
        host = nil
        session.end()
    }

    /// Called from the scene phase: iOS stops the camera while the app is in the background.
    func setPaused(_ paused: Bool) {
        guard host != nil, paused != isPaused else { return }
        isPaused = paused
        update()
        Task { await session.flush() }
    }

    private func update() {
        guard let host else { return }
        let state = CameraActivityAttributes.ContentState(
            isPaused: isPaused,
            isRecording: host.isRecording,
            recordingMode: host.settings.recordingMode,
            viewerCount: host.viewers.count,
            viewerNames: Array(host.viewers.map(\.name).prefix(2)),
            talker: host.talkingViewer,
            battery: host.batteryLevel,
            isCharging: host.isCharging,
            isHot: host.thermal == .serious || host.thermal == .critical,
            lastEvent: host.latestEvent.map { ActivityEvent(kind: $0.kind, label: $0.label, date: $0.date) }
        )
        if session.isActive {
            session.update(state)
        } else if UIApplication.shared.applicationState != .background {
            session.start(CameraActivityAttributes(cameraName: host.settings.name, startedAt: startedAt), state: state)
        }
    }
    #else
    func attach(_ host: CameraHost) {}
    func detach() {}
    func setPaused(_ paused: Bool) {}
    #endif
}
