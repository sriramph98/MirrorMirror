import Foundation

/// Hooks used by the test suite and on-device testing. All of them are inert in Release builds.
enum DebugSupport {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    /// `-MMAutoStartCamera`: open camera mode at launch (for driving a physical camera from a Mac).
    static let autoStartCamera = arguments.contains("-MMAutoStartCamera")
    /// `-MMSegmentSeconds 3`: short recording segments so tests don't wait a minute.
    static let segmentDuration: TimeInterval? = UserDefaults.standard.object(forKey: "MMSegmentSeconds") as? TimeInterval
    #else
    static let autoStartCamera = false
    static let segmentDuration: TimeInterval? = nil
    #endif

    /// Greppable console line, e.g. `MM camera: viewer connected`.
    static func log(_ area: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("MM \(area): \(message())")
        #endif
    }
}
