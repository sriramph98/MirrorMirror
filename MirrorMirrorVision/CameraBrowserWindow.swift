import SwiftUI
import MirrorUI

/// The main window: wordmark, a grid of live camera cards, and a bottom ornament with
/// "Open all", Settings and the privacy readout. Tapping a card opens that camera's window.
struct CameraBrowserWindow: View {
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var session: VisionSession
    @Environment(\.openWindow) private var openWindow

    @State private var showPairing = false
    @State private var showSettings = false
    @State private var showGallery = false

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: Space.xl)]

    var body: some View {
        VStack(spacing: 0) {
            header
            if hub.cameras.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                grid
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .ornament(attachmentAnchor: .scene(.bottom)) { bottomBar }
        .sheet(isPresented: $showPairing) {
            PairingSheet().environmentObject(hub)
        }
        .sheet(isPresented: $showSettings) {
            VisionSettingsSheet().environmentObject(hub)
        }
        .sheet(isPresented: $showGallery) {
            DesignSystemGallery(onClose: { showGallery = false })
                .frame(minWidth: 900, minHeight: 700)
        }
        .onAppear {
            hub.activate()
            session.browserVisible = true
            session.reconcile()
            handleLaunch()
        }
        .onDisappear {
            session.browserVisible = false
            session.reconcile()
        }
        .onChange(of: hub.cameras) { _, _ in session.reconcile() }
        .onChange(of: hub.pendingOpenCameraID) { _, id in
            guard let id else { return }
            hub.pendingOpenCameraID = nil
            openWindow(id: "camera", value: id)
        }
        .onOpenURL { url in session.handle(url, openWindow: openWindow) }
    }

    private func handleLaunch() {
        let launch = session.takeLaunchActions()
        switch launch.screen {
        case .pair: showPairing = true
        case .settings: showSettings = true
        case .gallery: showGallery = true
        default: break
        }
        if launch.autoWatch, let camera = hub.cameras.max(by: { $0.addedAt < $1.addedAt }) {
            // The scene has to finish appearing before a second window can open.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                openWindow(id: "camera", value: camera.id)
            }
        }
        if let id = hub.pendingOpenCameraID {
            hub.pendingOpenCameraID = nil
            openWindow(id: "camera", value: id)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.l) {
            Wordmark(size: 20)
            Spacer(minLength: Space.l)
            if !hub.cameras.isEmpty {
                ReadoutLine(["\(hub.cameras.count) camera\(hub.cameras.count == 1 ? "" : "s")",
                             "\(watchingCount) live"])
            }
            Button { showPairing = true } label: { Image(systemName: "plus") }
                .buttonStyle(.tool(size: VisionSize.toolSmall))
                .toolHover()
                .accessibilityLabel("Pair cameras")
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    private var watchingCount: Int {
        hub.cameras.filter { hub.connection(for: $0).phase == .connected }.count
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.xl) {
                ForEach(hub.cameras) { camera in
                    CameraCard(connection: hub.connection(for: camera), camera: camera,
                               reachability: hub.reachability(of: camera),
                               presence: hub.presence[camera.id],
                               isOpen: session.openCameraWindows.contains(camera.id)) {
                        openWindow(id: "camera", value: camera.id)
                    }
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.bottom, Space.xxxl + Space.xl)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        EmptyState(symbol: "video.badge.plus", title: "No cameras yet",
                   message: "Cameras on your Apple Account appear here by themselves. Pair from another device to add the rest.") {
            Button("Pair cameras") { showPairing = true }
                .buttonStyle(.primary)
                .frame(maxWidth: 260)
                .cardHover(Radius.control)
                .padding(.top, Space.s)
        }
    }

    // MARK: Ornament

    private var bottomBar: some View {
        HStack(spacing: Space.l) {
            Button {
                for camera in hub.cameras { openWindow(id: "camera", value: camera.id) }
            } label: {
                Label("Open all", systemImage: "rectangle.3.group")
            }
            .buttonStyle(.pill(isOn: false, prominent: true))
            .pillHover()
            .disabled(hub.cameras.isEmpty)
            .opacity(hub.cameras.isEmpty ? 0.4 : 1)
            .accessibilityHint("Opens a window for every camera")

            Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.tool(size: VisionSize.toolSmall))
                .toolHover()
                .accessibilityLabel("Settings")

            Rectangle().fill(Palette.stroke).frame(width: 1, height: 28)

            HStack(spacing: Space.s) {
                LED(hub.cloudAvailable ? Palette.ok : Palette.textTertiary)
                ReadoutLine(["Peer to peer", "End-to-end encrypted", hub.cloudAvailable ? "iCloud alerts" : "No cloud"])
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Privacy")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .glassBackgroundEffect(in: .capsule)
    }
}

// MARK: - Card

/// One camera: live thumbnail with corner readouts, name, connection LED and battery.
private struct CameraCard: View {
    @ObservedObject var connection: CameraConnection
    let camera: PairedCamera
    let reachability: ViewerHub.Reachability
    let presence: PresenceInfo?
    let isOpen: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Space.m) {
                picture
                HStack(alignment: .center, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(camera.name).type(.title).lineLimit(1)
                        LED(stateColor, label: stateLabel, pulsing: connection.phase == .connected)
                            .id(connection.phase == .connected)
                    }
                    Spacer(minLength: Space.s)
                    if isOpen {
                        Badge("Open", style: .accent)
                            .accessibilityLabel("Window open")
                    }
                    batteryChip
                }
                .padding(.horizontal, Space.xs)
            }
            .padding(Space.m)
            .background(.regularMaterial, in: .rect(cornerRadius: Radius.deck, style: .continuous))
        }
        .buttonStyle(.plain)
        .cardHover(Radius.deck)
        .accessibilityLabel(camera.name)
        .accessibilityValue(stateLabel)
        .accessibilityHint("Opens this camera in its own window")
    }

    private var picture: some View {
        Viewfinder(radius: Radius.panel) {
            ZStack {
                VideoSurface(sink: connection.sink)
                if connection.phase != .connected {
                    Palette.frame.opacity(0.72).transition(.opacity)
                }
                phaseReadout
            }
        } topLeading: {
            if connection.phase == .connected {
                LED(Palette.live, label: "Live", pulsing: true)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs + Space.xxs)
                    .background(Palette.frame.opacity(0.55), in: .continuous(Radius.badge))
            }
        } topTrailing: {
            HStack(spacing: Space.xs) {
                if let status = connection.status, connection.phase == .connected {
                    if status.nightActive { Badge("Night", style: .filled) }
                    if status.isRecording { Badge("Rec", style: .recording) }
                } else if presence?.isRecording == true {
                    Badge("Rec", style: .recording)
                }
            }
        } bottomLeading: {
            if connection.phase == .connected {
                let stats = connection.stats
                let items = [stats.height.map { "\(min(stats.width ?? $0, $0))" }, stats.fps.map { "\(Int($0.rounded())) fps" }].compactMap { $0 }
                if !items.isEmpty {
                    ReadoutLine(items, color: Palette.textPrimary)
                        .shadow(color: Palette.frame.opacity(0.9), radius: 3)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    @ViewBuilder
    private var phaseReadout: some View {
        switch connection.phase {
        case .connected:
            if !connection.hasVideo { ReadoutLine(["Waiting for video"], color: Palette.textSecondary) }
        case let .connecting(message):
            ReadoutLine([message.replacingOccurrences(of: "…", with: "")], color: Palette.textSecondary)
        case .failed:
            VStack(spacing: Space.s) {
                Image(systemName: "wifi.exclamationmark").font(.title2.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                ReadoutLine(["Can't reach camera"], color: Palette.textSecondary)
            }
        case .rejected:
            ReadoutLine(["Not allowed"], color: Palette.live)
        case .idle:
            ReadoutLine([reachabilityLabel], color: Palette.textTertiary)
        }
    }

    private var stateColor: Color {
        if connection.phase == .connected { return Palette.live }
        switch reachability {
        case .localNetwork, .online: return Palette.ok
        case .offline, .unknown: return Palette.textTertiary
        }
    }

    private var stateLabel: String {
        connection.phase == .connected ? "Live" : reachabilityLabel
    }

    private var reachabilityLabel: String {
        switch reachability {
        case .localNetwork: "On network"
        case .online: "Online"
        case let .offline(date):
            if let date { "Offline · \(date.formatted(.relative(presentation: .numeric)))" } else { "Offline" }
        case .unknown: "Not seen"
        }
    }

    @ViewBuilder
    private var batteryChip: some View {
        let level = connection.status?.batteryLevel ?? presence?.batteryLevel
        let charging = connection.status?.isCharging ?? presence?.isCharging ?? false
        if level != nil || charging {
            StatChip(level.map { "\(Int($0 * 100))%" } ?? "–",
                     symbol: batterySymbol(level, charging: charging),
                     tint: charging ? Palette.ok : ((level ?? 1) < 0.2 ? Palette.warn : Palette.textPrimary))
                .accessibilityLabel("Battery")
                .accessibilityValue(level.map { "\(Int($0 * 100)) percent\(charging ? ", charging" : "")" } ?? "Charging")
        }
    }
}
