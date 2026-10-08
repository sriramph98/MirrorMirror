import SwiftUI
import MirrorUI
import UniformTypeIdentifiers

/// Where the app is running. Compile-time so Mac-only code never ships in the iOS binary.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// "Mac", "iPad" or "iPhone", for sentences like "Use this Mac as a camera".
    static var deviceNoun: String {
        if isMac { return "Mac" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// SF Symbol for this device in "This device" headings (iPhone and iPad keep their "iphone").
    static var deviceSymbol: String { isMac ? "laptopcomputer" : "iphone" }
}

// MARK: - Hover

/// Pointer hover: a raised fill behind the content, like a Mac sidebar row lighting up.
/// Only a pointer can hover, so touch devices never see it.
private struct HoverHighlight<S: Shape>: ViewModifier {
    var shape: S
    /// Opaque content (a panel, a tool button) can't show a fill behind it, so it gets a
    /// lighter wash on top and a brighter edge instead.
    var opaque: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if hovering, !opaque {
                    shape.fill(Palette.raisedHigh).transition(.opacity)
                }
            }
            .overlay {
                if hovering, opaque {
                    shape.fill(Palette.textPrimary.opacity(0.05))
                        .overlay(shape.stroke(Palette.stroke, lineWidth: 1))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onHover { over in
                withAnimation(Motion.fade) { hovering = over }
            }
    }
}

extension View {
    /// Lights the view up under the pointer.
    func hoverHighlight(radius: CGFloat = Radius.control, opaque: Bool = false) -> some View {
        modifier(HoverHighlight(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), opaque: opaque))
    }

    /// Hover for the round `.tool()` buttons.
    func toolHover() -> some View {
        modifier(HoverHighlight(shape: Circle(), opaque: true))
    }

    /// Hover for `.pill()` buttons.
    func pillHover() -> some View {
        modifier(HoverHighlight(shape: Capsule(), opaque: true))
    }

    /// A keyboard shortcut that only exists on the Mac, so iPhone and iPad behave as before.
    @ViewBuilder
    func macKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        if Platform.isMac {
            keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}

// MARK: - Window scene

/// Reaches the UIWindowScene behind a SwiftUI window to set what SwiftUI can't: the minimum
/// size and (for camera windows) the title. Draws nothing.
struct WindowSceneConfigurator: UIViewRepresentable {
    var minimumSize: CGSize?
    var title: String?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.minimumSize = minimumSize
        view.title = title
        view.apply()
    }

    final class ProbeView: UIView {
        var minimumSize: CGSize?
        var title: String?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard let scene = window?.windowScene else { return }
            if let title { scene.title = title }
            #if targetEnvironment(macCatalyst)
            if let minimumSize { scene.sizeRestrictions?.minimumSize = minimumSize }
            #endif
        }
    }
}

/// Which cameras are open in their own windows, so the main window doesn't tear down a
/// connection a camera window is still showing (and vice versa).
@MainActor
enum CameraWindows {
    static var open: Set<String> = []
    /// The camera the main window is showing, if any.
    static var primaryShowing: String?

    static func isOpen(_ id: String) -> Bool { open.contains(id) }
}

// MARK: - Hiding the app (Mac)

enum MacApp {
    /// Hides every window, like ⌘H. The camera keeps running. Catalyst has no UIKit API for
    /// this, so it goes through AppKit by name; a no-op anywhere else.
    static func hide() {
        #if targetEnvironment(macCatalyst)
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() else { return }
        _ = app.perform(NSSelectorFromString("hide:"), with: nil)
        #endif
    }
}

// MARK: - Saving files (Mac)

/// A movie or picture on disk, for `fileExporter` ("Save As…" on the Mac).
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.movie, .mpeg4Movie, .quickTimeMovie, .jpeg, .png] }

    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }

    var contentType: UTType { UTType(filenameExtension: url.pathExtension) ?? .movie }
}

/// "Save As…" for a file the app made (an exported clip). On the Mac this is the standard save
/// panel; iPhone and iPad keep Share and Save to Photos, so the button only exists on the Mac.
private struct SaveAsButton: View {
    let url: URL
    let suggestedName: String
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: Space.s) {
            Button { saving = true } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
                .fileExporter(isPresented: $saving, document: ExportedFile(url: url),
                              contentType: ExportedFile(url: url).contentType, defaultFilename: suggestedName) { result in
                    if case let .failure(error) = result { message = error.localizedDescription }
                }
            if let message {
                Text(message).type(.footnote, color: Palette.textSecondary)
            }
        }
    }
}

extension View {
    /// On the Mac, adds a "Save As…" button under this one for the given file. Elsewhere nothing changes.
    @ViewBuilder
    func macSaveAs(_ url: URL?, suggestedName: String) -> some View {
        if Platform.isMac, let url {
            VStack(spacing: Space.s) {
                self
                SaveAsButton(url: url, suggestedName: suggestedName)
            }
        } else {
            self
        }
    }
}
