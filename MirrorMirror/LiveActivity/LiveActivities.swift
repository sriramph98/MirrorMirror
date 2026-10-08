import Foundation

/// App-launch setup for Live Activities.
@MainActor
enum LiveActivities {
    static func activate() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        LiveActivityActions.handler = { action in await MonitorActivityController.shared.handle(action) }
        Task {
            // Anything still on screen belongs to a previous run and can't be updated any more.
            await LiveActivitySession<MonitorActivityAttributes>.endLeftovers()
            await LiveActivitySession<CameraActivityAttributes>.endLeftovers()
            MonitorActivityController.shared.activate()
        }
        #endif
    }
}
