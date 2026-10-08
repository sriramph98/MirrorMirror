import SwiftUI

/// `-MMSnapshotDir <folder>`: every two seconds, draw every window of every scene into
/// `<folder>/w<scene>-<window>.png` (a Mac sheet is its own window). Lets the Mac app be
/// checked from a terminal that has no screen-recording permission (video layers come out
/// black; everything else is what's on screen).
///
/// `-MMDumpMenu`: on the Mac, print the menu bar (titles, shortcuts, enabled state) as
/// `MM menu:` lines a few seconds after launch, so the menus can be checked the same way.
///
/// Debug builds only.
enum DebugSnapshots {
    #if DEBUG
    static let directory: String? = UserDefaults.standard.string(forKey: "MMSnapshotDir")
    static let dumpMenu = ProcessInfo.processInfo.arguments.contains("-MMDumpMenu")
    #else
    static let directory: String? = nil
    static let dumpMenu = false
    #endif

    @MainActor
    static func startIfRequested() {
        #if DEBUG
        if let directory {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    capture(to: directory)
                }
            }
        }
        if dumpMenu {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                printMenuBar()
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func capture(to directory: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for (sceneIndex, scene) in scenes.enumerated() {
            for (windowIndex, window) in scene.windows.enumerated() where window.bounds.width > 0 && !window.isHidden {
                write(window, to: directory, name: "w\(sceneIndex)-\(windowIndex)")
                // A Mac sheet is hosted in a window of its own that the scene doesn't list; draw
                // each presented controller's view separately so sheets can be checked too.
                var presented = window.rootViewController?.presentedViewController
                var depth = 1
                while let controller = presented {
                    if let view = controller.view, view.bounds.width > 0 {
                        write(view, to: directory, name: "w\(sceneIndex)-\(windowIndex)-sheet\(depth)")
                    }
                    presented = controller.presentedViewController
                    depth += 1
                }
            }
        }
    }

    @MainActor
    private static func write(_ view: UIView, to directory: String, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? image.pngData()?.write(to: url, options: .atomic)
    }

    /// Walks AppKit's main menu by name (Catalyst has no UIKit API for reading it back).
    private static func printMenuBar() {
        #if targetEnvironment(macCatalyst)
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
              let menu = app.value(forKey: "mainMenu") as? NSObject else {
            print("MM menu: unavailable")
            return
        }
        printMenu(menu, indent: "")
        #endif
    }

    private static func printMenu(_ menu: NSObject, indent: String) {
        guard let items = menu.value(forKey: "itemArray") as? [NSObject] else { return }
        for item in items {
            let title = item.value(forKey: "title") as? String ?? ""
            if (item.value(forKey: "isSeparatorItem") as? Bool) == true {
                print("MM menu: \(indent)---")
                continue
            }
            let key = item.value(forKey: "keyEquivalent") as? String ?? ""
            let mask = (item.value(forKey: "keyEquivalentModifierMask") as? UInt) ?? 0
            let enabled = (item.value(forKey: "isEnabled") as? Bool) ?? true
            let state = (item.value(forKey: "state") as? Int) ?? 0
            var mods = ""
            if mask & (1 << 18) != 0 { mods += "⌃" }
            if mask & (1 << 19) != 0 { mods += "⌥" }
            if mask & (1 << 17) != 0 { mods += "⇧" }
            if mask & (1 << 20) != 0 { mods += "⌘" }
            let shortcut = key.isEmpty ? "" : "  [\(mods)\(keyName(key))]"
            print("MM menu: \(indent)\(state == 1 ? "✓ " : "")\(title)\(shortcut)\(enabled ? "" : "  (disabled)")")
            if let submenu = item.value(forKey: "submenu") as? NSObject {
                printMenu(submenu, indent: indent + "    ")
            }
        }
    }

    private static func keyName(_ key: String) -> String {
        switch key {
        case " ": "Space"
        case "\r": "↩"
        case "\u{1C}", "\u{F702}": "←"
        case "\u{1D}", "\u{F703}": "→"
        case "\u{1E}", "\u{F700}": "↑"
        case "\u{1F}", "\u{F701}": "↓"
        default: key.uppercased()
        }
    }
    #endif
}
