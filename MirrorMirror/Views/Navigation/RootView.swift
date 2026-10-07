import SwiftUI
import MirrorUI

/// Chooses the layout for the device: a stack on iPhone, a split view on iPad. Owns what both
/// share: camera mode (always full screen), hub activation and the debug launch hooks.
struct RootView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var router = CommandRouter(hub: ViewerHub.shared)
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCamera = false
    @State private var showPairDevices = false

    var body: some View {
        Group {
            // The Mac window is always the split view, however narrow it is dragged.
            if sizeClass == .regular || Platform.isMac {
                SplitRootView(showCamera: $showCamera)
            } else {
                HomeView(showCamera: $showCamera)
            }
        }
        .environment(\.commandRouter, router)
        .focusedSceneObject(router)
        // Mac: the window itself is canvas-coloured, so nothing white shows while columns resize.
        .background(Platform.isMac ? Palette.canvas.ignoresSafeArea() : nil)
        .background(WindowSceneConfigurator(minimumSize: Platform.isMac ? CGSize(width: 880, height: 600) : nil))
        .fullScreenCover(isPresented: $showCamera) { CameraModeView() }
        .sheet(isPresented: $showPairDevices) {
            // Presented at the window's root, where the hub isn't inherited (it is injected a level up).
            PairDeviceSheet().environmentObject(hub).mirrorSheet().presentationSizing(.form)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { router.becomeActive() } }
        .onAppear {
            hub.activate()
            router.becomeActive()
            router.useAsCamera = { showCamera = true }
            router.pairDevice = { showPairDevices = true }
            if ScreenHook.screen == nil { Notifications.requestAuthorization() }
            if ScreenHook.screen == "pairdevice" { showPairDevices = true }
            if DebugSupport.autoStartCamera { showCamera = true }
            if let url = DebugSupport.pairURL, let invite = PairingInvite(string: url) { hub.add(invite) }
            if DebugSupport.autoWatch, let camera = hub.cameras.last { hub.pendingOpenCameraID = camera.id }
        }
    }
}

// MARK: - iPad

/// What the iPad detail column shows.
enum SidebarItem: Hashable {
    case camera(String)
    case wall
    case recordings
    case settings
}

/// iPad: sidebar of cameras and this device's tools; the detail shows the selection in place.
struct SplitRootView: View {
    @EnvironmentObject private var hub: ViewerHub
    @ObservedObject private var store = RecordingStore.shared
    @Environment(\.commandRouter) private var router
    @Environment(\.openWindow) private var openWindow
    @Binding var showCamera: Bool

    @State private var selection: SidebarItem?
    @State private var visibility: NavigationSplitViewVisibility = .automatic
    @State private var isPortrait = false
    @State private var showAdd = false
    @State private var renaming: PairedCamera?
    @State private var newName = ""
    @State private var removing: PairedCamera?

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: Platform.isMac ? 220 : nil,
                                                ideal: Platform.isMac ? 240 : ControlSize.readableWidth / 2,
                                                max: Platform.isMac ? 300 : nil)
        } detail: {
            detail
                // The bar only exists to hold the sidebar button when the sidebar is tucked away;
                // on the Mac it is the title bar and always carries Add Camera and Use as Camera.
                .toolbar(detailBarVisible ? .visible : .hidden, for: .navigationBar)
                .toolbarBackground(detailBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { if Platform.isMac { macToolbar } }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < $0.size.height } action: { isPortrait = $0 }
        .sheet(isPresented: $showAdd) { AddCameraView().mirrorSheet().presentationSizing(.page) }
        .cameraMenuAlerts(renaming: $renaming, newName: $newName, removing: $removing)
        .onAppear {
            if selection == nil { selection = hub.cameras.first.map { .camera($0.id) } }
            switch ScreenHook.screen {
            case "add", "addlink": showAdd = true
            case "settings", "gallery": selection = .settings
            case "recordings", "player": selection = .recordings
            case "wall": selection = .wall
            case "sidebar": visibility = .all
            case "window":
                // Mac: the first camera in its own window too, for checking multi-window from a terminal.
                if Platform.isMac, let first = hub.cameras.first { openWindow(value: first.id) }
            default: break
            }
            openPending()
            registerCommands()
            publishSelection()
        }
        .onChange(of: selection) { _, _ in publishSelection() }
        .onChange(of: visibility) { _, _ in publishSidebar() }
        .onChange(of: isPortrait) { _, _ in publishSidebar() }
        .onChange(of: hub.pendingOpenCameraID) { _, _ in openPending() }
        .onChange(of: hub.cameras) { _, cameras in
            if selection == nil, let first = cameras.first {
                // The first camera to arrive becomes the selection.
                select(.camera(first.id))
            } else if case let .camera(id)? = selection, !cameras.contains(where: { $0.id == id }) {
                // A removed camera can't stay selected.
                selection = cameras.first.map { .camera($0.id) }
            } else if selection == .wall, cameras.count < 2 {
                selection = cameras.first.map { .camera($0.id) }
            }
            publishSelection()
        }
    }

    /// The sidebar is tucked away: collapsed by the user, or hidden by default in portrait.
    private var detailBarVisible: Bool {
        Platform.isMac || visibility == .detailOnly || (isPortrait && visibility == .automatic)
    }

    // MARK: Mac

    /// Title-bar buttons, in addition to the sidebar rows.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAdd = true } label: { Label("Add Camera", systemImage: "plus") }
                .help("Add a camera (⌘N)")
            Button { showCamera = true } label: { Label("Use as Camera", systemImage: "video.fill") }
                .help("Use this Mac as a camera (⇧⌘C)")
        }
    }

    /// Whether the sidebar column is on screen, for the View menu's Show/Hide Sidebar title.
    private var sidebarShowing: Bool {
        switch visibility {
        case .detailOnly: false
        case .automatic: !isPortrait
        default: true
        }
    }

    private func publishSidebar() {
        router?.sidebarVisible = sidebarShowing
    }

    /// The camera shown in the detail, if the selection is one.
    private var selectedCameraID: String? {
        if case let .camera(id) = selection { return id }
        return nil
    }

    /// What the menu bar acts on in this window.
    private func registerCommands() {
        guard let router else { return }
        router.addCamera = { showAdd = true }
        router.showSettings = { select(.settings) }
        router.selectCamera = { index in
            guard hub.cameras.indices.contains(index) else { return }
            select(.camera(hub.cameras[index].id))
        }
        router.toggleSidebar = {
            withAnimation(Motion.smooth) { visibility = sidebarShowing ? .detailOnly : .all }
        }
        publishSidebar()
    }

    /// Keeps the menu's checkmark and "Open in New Window" in step with the detail column.
    private func publishSelection() {
        CameraWindows.primaryShowing = selectedCameraID
        guard let router else { return }
        router.selectedCameraIndex = selectedCameraID.flatMap { id in hub.cameras.firstIndex { $0.id == id } }
        if Platform.isMac, let id = selectedCameraID {
            router.openInNewWindow = { openWindow(value: id) }
        } else {
            router.openInNewWindow = nil
        }
    }

    /// Pictures sit on the black frame; lists and forms on the canvas.
    private var detailBackground: Color {
        switch selection {
        case .recordings, .settings: Palette.canvas
        default: Palette.frame
        }
    }

    private func select(_ item: SidebarItem) {
        if case let .camera(id) = item { WallHandoff.keepConnected = id }
        selection = item
        // In portrait the sidebar covers the picture; get it out of the way once something is chosen.
        if isPortrait, visibility != .detailOnly, visibility != .automatic {
            withAnimation(Motion.smooth) { visibility = .detailOnly }
        }
    }

    private func openPending() {
        guard let id = hub.pendingOpenCameraID, hub.camera(id: id) != nil else { return }
        hub.pendingOpenCameraID = nil
        select(.camera(id))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    sidebarHeading("Cameras") {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.tool(size: ControlSize.tool))
                            .toolHover()
                            .accessibilityLabel("Add camera")
                    }
                    if hub.cameras.isEmpty {
                        Text("No cameras yet").type(.footnote, color: Palette.textTertiary)
                            .padding(.horizontal, Space.m)
                            .padding(.vertical, Space.s)
                    }
                    ForEach(hub.cameras) { camera in
                        SidebarCameraRow(camera: camera, connection: hub.connection(for: camera),
                                         reachability: hub.reachability(of: camera), presence: hub.presence[camera.id],
                                         isSelected: selection == .camera(camera.id)) {
                            select(.camera(camera.id))
                        }
                        .contextMenu { CameraMenu(camera: camera, renaming: $renaming, newName: $newName, removing: $removing) }
                        // Mac: double-click opens the camera in its own window.
                        .simultaneousGesture(Platform.isMac ? TapGesture(count: 2).onEnded { openWindow(value: camera.id) } : nil)
                    }
                    if hub.cameras.count >= 2 {
                        SidebarRow(symbol: "square.grid.2x2.fill", title: "All cameras",
                                   value: "\(hub.cameras.count)", isSelected: selection == .wall) { select(.wall) }
                    }
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    sidebarHeading("This device") { EmptyView() }
                    SidebarRow(symbol: "video.fill", title: "Use as camera", value: nil, isSelected: false) {
                        showCamera = true
                    }
                    SidebarRow(symbol: "film.stack", title: "Recordings",
                               value: store.segments.isEmpty ? nil : "\(store.segments.count)",
                               isSelected: selection == .recordings) { select(.recordings) }
                    SidebarRow(symbol: "gearshape.fill", title: "Settings", value: nil,
                               isSelected: selection == .settings) { select(.settings) }
                }

                HStack(spacing: Space.s) {
                    Image(systemName: "lock.fill").font(.caption2.weight(.bold)).foregroundStyle(Palette.textTertiary)
                    ReadoutLine(["P2P", "End-to-end"], color: Palette.textTertiary)
                }
                .padding(.horizontal, Space.s)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Peer to peer, end-to-end encrypted")
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.xl)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) { Wordmark(size: 14) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func sidebarHeading<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).type(.caps, color: Palette.textTertiary)
            Spacer()
            trailing()
        }
        .padding(.leading, Space.s)
        .frame(minHeight: ControlSize.tool)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .camera(id):
            if let camera = hub.camera(id: id) {
                LiveView(connection: hub.connection(for: camera), onClose: nil)
                    .id(id)
            } else {
                noCameras
            }
        case .wall:
            GridView(embedded: true) { select(.camera($0.id)) }
        case .recordings:
            RecordingsView(onClose: nil)
        case .settings:
            ViewerSettingsView(onClose: nil)
        case nil:
            noCameras
        }
    }

    private var noCameras: some View {
        EmptyState(symbol: "video.badge.plus", title: "No cameras yet",
                   message: "Open MirrorMirror on a spare iPhone or iPad and tap Use as camera, or scan a camera's pairing code.") {
            VStack(spacing: Space.s) {
                Button { showAdd = true } label: { Label("Add camera", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.accent)
                Button { showCamera = true } label: { Text("Use this \(Platform.deviceNoun) as a camera") }
                    .buttonStyle(.pill())
            }
            .padding(.top, Space.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(Palette.frame)
    }
}

/// `-MMScreen add|settings|recordings|player|wall|gallery`: open that screen at launch, for
/// screenshots and UI checks. Inert in Release builds.
enum ScreenHook {
    #if DEBUG
    static let screen: String? = UserDefaults.standard.string(forKey: "MMScreen")
    #else
    static let screen: String? = nil
    #endif
}

/// Lets the wall keep one connection open when the iPad hands that camera to the live view,
/// so the wall tearing down its tiles doesn't drop the camera the user just opened.
@MainActor
enum WallHandoff {
    static var keepConnected: String?
}

// MARK: - Sidebar rows

private struct SidebarRow: View {
    let symbol: String
    let title: String
    let value: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                    .frame(width: ControlSize.tool / 2)
                Text(title).type(.headline, color: isSelected ? Palette.accent : Palette.textPrimary)
                Spacer(minLength: Space.s)
                if let value { Text(value).type(.readout, color: Palette.textTertiary) }
            }
            .sidebarRowChrome(isSelected: isSelected)
        }
        .buttonStyle(CardPressStyle())
        .hoverHighlight()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarCameraRow: View {
    let camera: PairedCamera
    @ObservedObject var connection: CameraConnection
    let reachability: ViewerHub.Reachability
    let presence: PresenceInfo?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let link = CameraLinkState(reachability: reachability, presence: presence, connection: connection)
        let power = CameraPower(presence: presence, connection: connection)
        Button(action: action) {
            HStack(spacing: Space.m) {
                LED(link.color, pulsing: link.kind == .live)
                    .frame(width: ControlSize.tool / 2)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(camera.name).type(.headline, color: isSelected ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                    Text(link.label).type(.caps, color: Palette.textTertiary)
                }
                Spacer(minLength: Space.s)
                if power.known {
                    StatChip(power.percentText, symbol: power.symbol, tint: power.tint)
                }
            }
            .sidebarRowChrome(isSelected: isSelected)
        }
        .buttonStyle(CardPressStyle())
        .hoverHighlight()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    func sidebarRowChrome(isSelected: Bool) -> some View {
        self
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(minHeight: ControlSize.toolLarge)
            .background(isSelected ? Palette.raised : Color.clear, in: .continuous(Radius.control))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(.continuous(Radius.control))
    }
}

// MARK: - Swipe back with hidden navigation bars

/// Our pushed screens draw their own headers and hide the system bar, which would otherwise
/// disable the edge-swipe back gesture. Re-enable it whenever there is something to pop.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
