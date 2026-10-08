import Combine
import UIKit
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Puts the camera you're listening to on the Lock Screen and in the Dynamic Island.
///
/// The camera you hear is `ViewerHub.audioFocus` (the open live view, or the grid tile with
/// sound). Its activity starts once it connects, while the app is still on screen (iOS only
/// lets apps start activities from the foreground; the system hides it until you leave), and
/// ends when the live view closes, sound moves to another camera, or the setting is off.
@MainActor
final class MonitorActivityController {
    static let shared = MonitorActivityController()

    private static let settingKey = "viewer.liveActivity"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: settingKey)
            shared.refresh()
        }
    }

    /// iPhone only: iPad and Mac have no Lock Screen activities or Dynamic Island.
    static var isAvailable: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// Off in iOS Settings › MirrorMirror › Live Activities.
    static var isAllowedBySystem: Bool {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private let session = LiveActivitySession<MonitorActivityAttributes>(name: "monitor")
    private weak var connection: CameraConnection?
    private var connectionObserver: AnyCancellable?
    private var hubObserver: AnyCancellable?

    func activate() {
        guard Self.isAvailable, hubObserver == nil else { return }
        hubObserver = ViewerHub.shared.$audioFocus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// Works out which camera (if any) should have the activity and brings it up to date.
    func refresh() {
        guard Self.isAvailable else { return }
        let hub = ViewerHub.shared
        var target: CameraConnection?
        if Self.isEnabled, let id = hub.audioFocus, !id.isEmpty {
            target = hub.existingConnection(id: id)
        }
        if target !== connection {
            follow(target)
        } else {
            update()
        }
    }

    private func follow(_ target: CameraConnection?) {
        session.reset()
        connection = target
        connectionObserver = target?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    private func update() {
        guard let connection else { return }
        switch connection.phase {
        case .connected:
            let state = state(for: connection, link: .live)
            if session.isActive {
                session.update(state)
            } else if UIApplication.shared.applicationState != .background {
                session.start(MonitorActivityAttributes(cameraID: connection.id, cameraName: connection.camera.name), state: state)
            }
        case .connecting, .failed:
            session.update(state(for: connection, link: .reconnecting))
        case .idle, .rejected:
            session.end()
        }
    }

    private func state(for connection: CameraConnection, link: MonitorActivityAttributes.ContentState.Link)
        -> MonitorActivityAttributes.ContentState {
        let path: String? = switch connection.stats.path {
        case .unknown: nil
        case .local: "LOCAL"
        case .direct: "P2P"
        case .relay: "RELAY"
        }
        return MonitorActivityAttributes.ContentState(
            link: link,
            isMuted: !connection.isListening,
            soundLevel: connection.isListening ? LiveActivityFormat.meterLevel(connection.stats.audioLevel) : 0,
            path: path,
            cameraRecording: connection.status?.isRecording ?? false,
            cameraBattery: connection.status?.batteryLevel,
            otherTalker: connection.otherTalker,
            isTalking: connection.isTalking,
            lastEvent: connection.latestEvent.map { ActivityEvent(kind: $0.kind, label: $0.label, date: $0.date) }
        )
    }

    // MARK: Lock Screen buttons

    func handle(_ action: LiveActivityActions.Action) async {
        switch action {
        case let .toggleMute(cameraID):
            guard let connection, connection.id == cameraID else { return await endOrphans() }
            connection.isListening.toggle()
            update()
            await session.flush()

        case let .stopTalking(cameraID):
            guard let connection, connection.id == cameraID else { return await endOrphans() }
            await connection.setTalking(false)
            update()
            await session.flush()

        case let .stopMonitoring(cameraID):
            guard let connection, connection.id == cameraID else { return await endOrphans() }
            // The live view closes itself (and disconnects); a grid tile just stops being heard.
            AppRoutes.shared.stopCameraID = cameraID
            try? await Task.sleep(for: .milliseconds(800))
            if AppRoutes.shared.stopCameraID == cameraID { AppRoutes.shared.stopCameraID = nil }
            if self.connection === connection {
                if ViewerHub.shared.audioFocus == cameraID { ViewerHub.shared.audioFocus = "" }
                session.end()
            }
        }
    }

    /// A button on an activity this run doesn't own (left from before a relaunch).
    private func endOrphans() async {
        if !session.isActive { await LiveActivitySession<MonitorActivityAttributes>.endLeftovers() }
    }
    #else
    func activate() {}
    func refresh() {}
    #endif
}
