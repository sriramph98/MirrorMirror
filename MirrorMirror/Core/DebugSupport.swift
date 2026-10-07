import Foundation

/// Hooks used by the test suite and on-device testing. All of them are inert in Release builds.
enum DebugSupport {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    /// `-MMAutoStartCamera`: open camera mode at launch (for driving a physical camera from a Mac).
    static let autoStartCamera = arguments.contains("-MMAutoStartCamera")
    /// `-MMSegmentSeconds 3`: short recording segments so tests don't wait a minute.
    static let segmentDuration: TimeInterval? = UserDefaults.standard.object(forKey: "MMSegmentSeconds") as? TimeInterval
    /// `-MMPairURL mirrormirror://pair?...`: add this camera at launch (pairing a physical viewer from a Mac).
    static let pairURL: String? = UserDefaults.standard.string(forKey: "MMPairURL")
    /// `-MMAutoWatch`: open the most recently added camera's live view at launch.
    static let autoWatch = arguments.contains("-MMAutoWatch")
    #else
    static let pairURL: String? = nil
    static let autoWatch = false
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
