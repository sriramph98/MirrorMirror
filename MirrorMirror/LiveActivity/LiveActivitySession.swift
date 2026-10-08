#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// One running Live Activity, updated from inside the app. Nothing updates it remotely, so:
/// - updates are coalesced (at most one a second, only when something changed);
/// - every update carries a stale date, refreshed by a heartbeat, so if the app is closed the
///   banner says "Not updating" instead of showing old values as live;
/// - if the person swipes it away, it stays away until the next session.
@MainActor
final class LiveActivitySession<Attributes: ActivityAttributes> {
    private let name: String
    private var activity: Activity<Attributes>?
    private var latest: Attributes.ContentState?
    private var sent: Attributes.ContentState?
    private var lastSent = Date.distantPast
    private var flushTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var stateWatcher: Task<Void, Never>?
    /// The person dismissed it (or iOS ended it); don't start another until `reset()`.
    private(set) var wasDismissed = false

    private let minimumInterval: TimeInterval = 1
    private let heartbeatInterval: TimeInterval = 60
    private let staleAfter: TimeInterval = 150

    init(name: String) { self.name = name }

    var isActive: Bool { activity != nil }
    var attributes: Attributes? { activity?.attributes }

    /// Starts the activity. iOS only allows this while the app is in the foreground.
    @discardableResult
    func start(_ attributes: Attributes, state: Attributes.ContentState) -> Bool {
        guard activity == nil, !wasDismissed, ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            let activity = try Activity.request(attributes: attributes, content: content(state))
            self.activity = activity
            latest = state
            sent = state
            lastSent = Date()
            heartbeat = Task { [weak self, heartbeatInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(heartbeatInterval))
                    await self?.push(force: true)
                }
            }
            stateWatcher = Task { [weak self] in
                for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                    self?.endedOutside(activity)
                    return
                }
            }
            DebugSupport.log("live-activity", "\(name) started")
            return true
        } catch {
            DebugSupport.log("live-activity", "\(name) couldn't start: \(error.localizedDescription)")
            return false
        }
    }

    func update(_ state: Attributes.ContentState) {
        guard activity != nil else { return }
        latest = state
        guard state != sent, flushTask == nil else { return }
        let wait = max(0, minimumInterval - Date().timeIntervalSince(lastSent))
        flushTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            await self?.push(force: false)
        }
    }

    /// Sends the latest state now (a button was pressed and the person is looking at it).
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        await push(force: false)
    }

    func end(immediately: Bool = true) {
        stopTasks()
        guard let activity else { return }
        self.activity = nil
        let final = latest.map(content)
        Task { await activity.end(final, dismissalPolicy: immediately ? .immediate : .default) }
        DebugSupport.log("live-activity", "\(name) ended")
    }

    /// A new session (another camera, the camera restarted): a dismissal no longer applies.
    func reset() {
        end()
        wasDismissed = false
        latest = nil
        sent = nil
    }

    /// Activities left over from a previous run can't be updated any more; clear them at launch.
    static func endLeftovers() async {
        for activity in Activity<Attributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func push(force: Bool) async {
        guard let activity, let state = latest, force || state != sent else { return }
        sent = state
        lastSent = Date()
        await activity.update(content(state))
    }

    private func endedOutside(_ ended: Activity<Attributes>) {
        guard activity?.id == ended.id else { return }
        stopTasks()
        activity = nil
        wasDismissed = true
        DebugSupport.log("live-activity", "\(name) dismissed")
    }

    private func stopTasks() {
        flushTask?.cancel()
        flushTask = nil
        heartbeat?.cancel()
        heartbeat = nil
        stateWatcher?.cancel()
        stateWatcher = nil
    }

    private func content(_ state: Attributes.ContentState) -> ActivityContent<Attributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
    }
}
#endif
