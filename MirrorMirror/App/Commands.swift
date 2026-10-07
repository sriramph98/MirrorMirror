import SwiftUI
import Combine

// MARK: - Router

/// What the menu bar and keyboard shortcuts act on. One per window: the root view of the
/// window registers its actions, and whichever `LiveView` is on screen registers its own.
/// Published through `focusedSceneObject`, so the menus follow the key window.
@MainActor
final class CommandRouter: ObservableObject {
    /// The live view currently on screen in this window, if any.
    @Published var live: LiveCommands?
    /// Which live view registered `live`, so one leaving doesn't unregister its replacement.
    var liveOwner: UUID?
    /// Mirrors the hub so the View menu can list Cameras 1–9.
    @Published private(set) var cameras: [PairedCamera] = []
    /// Index of the camera the window is showing, for the checkmark in the Cameras list.
    @Published var selectedCameraIndex: Int?
    /// Nil when the window has no sidebar (a camera window); true while it is showing.
    @Published var sidebarVisible: Bool?

    // Window-level actions. Nil when the window can't do that (a camera window has no sidebar).
    // Published so the menu items enable and disable as soon as a window registers them.
    @Published var addCamera: (() -> Void)?
    @Published var useAsCamera: (() -> Void)?
    @Published var pairDevice: (() -> Void)?
    @Published var showSettings: (() -> Void)?
    @Published var selectCamera: ((Int) -> Void)?
    @Published var toggleSidebar: (() -> Void)?
    @Published var openInNewWindow: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(hub: ViewerHub) {
        hub.$cameras.receive(on: RunLoop.main).sink { [weak self] in self?.cameras = $0 }.store(in: &cancellables)
    }

    /// This window became key: UIKit-built menu items act on it from now on.
    func becomeActive() {
        #if targetEnvironment(macCatalyst)
        CommandRouter.active = self
        #endif
    }
}

/// A snapshot of what the live view can do right now, plus the state the menu titles need.
struct LiveCommands {
    var cameraName: String
    var isConnected: Bool
    var isLive: Bool
    var isPlaying: Bool
    var canRewind: Bool
    var isMuted: Bool
    var isTalking: Bool
    var pipSupported: Bool
    var pipActive: Bool

    var goLive: () -> Void
    var rewind60: () -> Void
    var togglePause: () -> Void
    var toggleMute: () -> Void
    var toggleTalk: () -> Void
    var togglePiP: () -> Void
    var snapshot: () -> Void
    var export: () -> Void
}

private struct CommandRouterKey: EnvironmentKey {
    static let defaultValue: CommandRouter? = nil
}

extension EnvironmentValues {
    /// The window's router, for views that register actions. Optional so previews and tests
    /// that don't inject one still work.
    var commandRouter: CommandRouter? {
        get { self[CommandRouterKey.self] }
        set { self[CommandRouterKey.self] = newValue }
    }
}

// MARK: - Menus

/// The Mac menu bar: a Camera menu, the View menu's playback and window items, and Settings…
/// (⌘,) in the app menu. Items act through the key window's `CommandRouter` and are disabled
/// when that window can't act.
struct MirrorCommands: Commands {
    @FocusedObject private var router: CommandRouter?

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router?.showSettings?() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(router?.showSettings == nil)
        }

        // The Camera menu is built with UIKit in `MacCameraMenu` below: SwiftUI's `CommandMenu`
        // never reaches the Catalyst menu bar (checked with -MMDumpMenu), while groups inserted
        // into the system menus, like this View menu group, do.
        CommandGroup(before: .toolbar) {
            let live = router?.live
            Button("Live") { live?.goLive() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(live == nil || live?.isLive == true)
            Button("Back 60 Seconds") { live?.rewind60() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(live?.canRewind != true)
            Button(live?.isPlaying == false ? "Resume" : "Pause") { live?.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(live == nil || live?.isLive == true)
            Divider()
            Button(live?.isMuted == true ? "Unmute Camera Sound" : "Mute Camera Sound") { live?.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(live == nil)
            Button(live?.isTalking == true ? "Stop Talking" : "Talk") { live?.toggleTalk() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(live?.isConnected != true)
            Button(live?.pipActive == true ? "Leave Picture in Picture" : "Picture in Picture") { live?.togglePiP() }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(live?.pipSupported != true)
            Divider()
            Button("Snapshot") { live?.snapshot() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(live?.isConnected != true)
            Button("Export Clip…") { live?.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(live?.isConnected != true)
            Divider()
            Button("Open Camera in New Window") { router?.openInNewWindow?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(router?.openInNewWindow == nil)
            cameraList
            Button(router?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { router?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(router?.toggleSidebar == nil)
        }
    }

    /// Cameras 1–9: ⌘1 … ⌘9 show the nth camera of the sidebar in this window.
    @ViewBuilder
    private var cameraList: some View {
        if let router, !router.cameras.isEmpty {
            Menu("Cameras") {
                ForEach(Array(router.cameras.prefix(9).enumerated()), id: \.element.id) { index, camera in
                    Toggle(isOn: Binding(get: { router.selectedCameraIndex == index },
                                         set: { _ in router.selectCamera?(index) })) {
                        Text(camera.name)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .disabled(router.selectCamera == nil)
            Divider()
        }
    }
}

// MARK: - Camera menu (UIKit)

#if targetEnvironment(macCatalyst)
extension CommandRouter {
    /// The router of the key window, for the UIKit-built Camera menu. SwiftUI's menus find the
    /// key window through `focusedSceneObject`; UIKit's go through here.
    static weak var active: CommandRouter?
}

/// The Camera menu: Use This Mac as Camera (⇧⌘C), Add Camera… (⌘N), Pair Apple TV or
/// Vision Pro… (⇧⌘P), Settings…. Built with `UIMenuBuilder` because SwiftUI's `CommandMenu`
/// doesn't appear in the Catalyst menu bar. Actions reach `AppDelegate` through the responder
/// chain and act on the key window's router; `validate` keeps them enabled only when it can act.
@MainActor
enum MacCameraMenu {
    static let identifier = UIMenu.Identifier("com.sriramph.mirrormirror.menu.camera")

    static func install(in builder: UIMenuBuilder) {
        let menu = UIMenu(title: "Camera", identifier: identifier, children: [
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Use This Mac as Camera", action: #selector(AppDelegate.menuUseAsCamera(_:)),
                             input: "c", modifierFlags: [.command, .shift]),
                UIKeyCommand(title: "Add Camera…", action: #selector(AppDelegate.menuAddCamera(_:)),
                             input: "n", modifierFlags: .command),
                UIKeyCommand(title: "Pair Apple TV or Vision Pro…", action: #selector(AppDelegate.menuPairDevice(_:)),
                             input: "p", modifierFlags: [.command, .shift]),
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Settings…", action: #selector(AppDelegate.menuShowSettings(_:))),
            ]),
        ])
        builder.insertSibling(menu, afterMenu: .view)
    }

    /// Enabled state for one of the menu's commands; nil when the command isn't ours.
    static func canPerform(_ action: Selector?) -> Bool? {
        let router = CommandRouter.active
        switch action {
        case #selector(AppDelegate.menuUseAsCamera(_:)): return router?.useAsCamera != nil
        case #selector(AppDelegate.menuAddCamera(_:)): return router?.addCamera != nil
        case #selector(AppDelegate.menuPairDevice(_:)): return router?.pairDevice != nil
        case #selector(AppDelegate.menuShowSettings(_:)): return router?.showSettings != nil
        default: return nil
        }
    }
}

extension AppDelegate {
    @objc func menuUseAsCamera(_ sender: Any?) { CommandRouter.active?.useAsCamera?() }
    @objc func menuAddCamera(_ sender: Any?) { CommandRouter.active?.addCamera?() }
    @objc func menuPairDevice(_ sender: Any?) { CommandRouter.active?.pairDevice?() }
    @objc func menuShowSettings(_ sender: Any?) { CommandRouter.active?.showSettings?() }
}
#endif
