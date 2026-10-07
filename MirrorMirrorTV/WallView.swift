import SwiftUI
import MirrorUI

/// Home: every paired camera on one wall. Focus moves between tiles; the focused tile gets the
/// sound after a beat; Select opens it full screen.
struct WallView: View {
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @FocusState private var focusedCamera: String?
    @FocusState private var focusedBar: Bar?
    @State private var audioTask: Task<Void, Never>?

    enum Bar: Hashable { case pair, settings }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            header
            if hub.cameras.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in grid(in: geo.size) }
            }
        }
        .padding(.horizontal, TVSize.margin)
        .padding(.vertical, Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(Palette.frame)
        .onAppear {
            router.keepConnected = nil
            hub.cameras.forEach { hub.connection(for: $0).connect() }
            if hub.audioFocus == nil || hub.audioFocus?.isEmpty == true {
                hub.audioFocus = hub.cameras.first?.id ?? ""
            }
        }
        .onDisappear {
            audioTask?.cancel()
            for camera in hub.cameras where camera.id != router.keepConnected {
                hub.connection(for: camera).disconnect()
            }
        }
        .onChange(of: hub.cameras) { _, cameras in
            cameras.forEach { hub.connection(for: $0).connect() }
        }
        .onChange(of: focusedCamera) { _, id in
            // Sound follows focus, after a beat so flicking across the wall doesn't stutter.
            guard let id else { return }
            audioTask?.cancel()
            audioTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                hub.audioFocus = id
            }
        }
        #if DEBUG
        .onChange(of: router.debugCommand) { _, command in
            guard let command else { return }
            let parts = command.split(separator: "/").map(String.init)
            if parts.first == "focus", parts.count > 1, let index = Int(parts[1]), hub.cameras.indices.contains(index) {
                focusedCamera = hub.cameras[index].id
            } else if parts.first == "focus", parts.count > 1, parts[1] == "pair" {
                focusedBar = .pair
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.xl) {
            Wordmark(size: 30)
            Spacer(minLength: Space.xl)
            HStack(spacing: Space.l) {
                Text("Cameras").tv(.caps)
                Text("\(hub.cameras.count)").tv(.readoutLarge, color: Palette.textPrimary)
            }
            .accessibilityElement(children: .combine)
            Button { router.screen = .pair } label: {
                Label("Pair", systemImage: "plus")
            }
            .buttonStyle(.tvPill())
            .focused($focusedBar, equals: .pair)
            .accessibilityLabel("Pair a device")
            Button { router.screen = .settings } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.tvTool())
            .focused($focusedBar, equals: .settings)
            .accessibilityLabel("Settings")
        }
        .focusSection()
    }

    // MARK: Grid

    private func columnCount(_ count: Int) -> Int {
        switch count {
        case ...1: 1
        case 2...4: 2
        default: 3
        }
    }

    @ViewBuilder
    private func grid(in size: CGSize) -> some View {
        let cameras = hub.cameras
        let columns = columnCount(cameras.count)
        let rows = Int(ceil(Double(cameras.count) / Double(columns)))
        // Tiles keep 16:9 and share the space; the focus bracket inset needs breathing room.
        let inset = Space.xl * 2
        let tileWidth = (size.width - inset - CGFloat(columns - 1) * TVSize.gutter) / CGFloat(columns)
        let maxTileHeight = (size.height - inset - CGFloat(rows - 1) * TVSize.gutter) / CGFloat(min(rows, 2))
        let tileHeight = min(tileWidth * 9 / 16, maxTileHeight)
        let width = tileHeight * 16 / 9
        let gridItems = Array(repeating: GridItem(.fixed(width), spacing: TVSize.gutter), count: columns)

        ScrollView(.vertical) {
            LazyVGrid(columns: gridItems, spacing: TVSize.gutter) {
                ForEach(cameras) { camera in
                    WallTile(connection: hub.connection(for: camera),
                             reachability: hub.reachability(of: camera),
                             audioOn: hub.audioFocus == camera.id) {
                        router.open(camera)
                    }
                    .frame(width: width, height: tileHeight)
                    .focused($focusedCamera, equals: camera.id)
                }
            }
            .padding(inset / 2)
            .frame(maxWidth: .infinity, minHeight: rows <= 2 ? size.height : nil)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .focusSection()
    }

    // MARK: Empty

    private var emptyState: some View {
        TVEmptyState(symbol: "video.badge.plus", title: "No cameras yet",
                     message: "Pair this Apple TV with the iPhone or iPad that has your cameras. Devices on the same Apple Account appear here on their own.") {
            Button { router.screen = .pair } label: { Label("Pair", systemImage: "plus") }
                .buttonStyle(.tvPill(isOn: true))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tile

private struct WallTile: View {
    @ObservedObject var connection: CameraConnection
    let reachability: ViewerHub.Reachability
    let audioOn: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Viewfinder(radius: Radius.viewfinder) {
                VideoSurface(sink: connection.sink, fill: true)
                if connection.phase != .connected { Palette.frame.opacity(0.6) }
                phaseOverlay
            } topLeading: {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(connection.camera.name).tv(.caps, color: Palette.textPrimary).lineLimit(1)
                    TVLED(ledColor, label: ledLabel, pulsing: connection.phase == .connected).id(ledLabel)
                }
                .padding(Space.m)
                .shadow(color: Palette.frame.opacity(0.8), radius: Space.s)
            } topTrailing: {
                HStack(spacing: Space.m) {
                    if connection.status?.isRecording == true, connection.phase == .connected { TVBadge("Rec", style: .recording) }
                    if let battery = connection.tvBattery {
                        HStack(spacing: Space.s) {
                            Image(systemName: battery.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(battery.tint)
                            Text(battery.text).tv(.readout, color: battery.tint)
                        }
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .background(Palette.frame.opacity(0.55), in: .continuous(Radius.chip))
                        .accessibilityLabel("Battery \(battery.text)")
                    }
                }
                .padding(Space.m)
            } bottomLeading: {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let event = connection.latestEvent, context.date.timeIntervalSince(event.date) < 60 {
                        HStack(spacing: Space.s) {
                            Image(systemName: event.kind.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.onAccent)
                            Text(event.label).tv(.readout, color: Palette.onAccent)
                        }
                        .padding(.horizontal, Space.l)
                        .padding(.vertical, Space.s + Space.xxs)
                        .background(Palette.accent, in: .continuous(Radius.chip))
                        .padding(Space.m)
                        .transition(.opacity)
                    }
                }
            } bottomTrailing: {
                if audioOn {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 52, height: 52)
                        .background(Palette.accent, in: Circle())
                        .padding(Space.m)
                        .transition(.opacity)
                        .accessibilityLabel("Sound from this camera")
                }
            }
            .animation(Motion.fade, value: audioOn)
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel("\(connection.camera.name), \(ledLabel)")
        .accessibilityHint("Opens the camera full screen")
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch connection.phase {
        case .connecting, .idle:
            if !connection.hasVideo {
                VStack(spacing: Space.m) {
                    ProgressView().tint(Palette.textSecondary).scaleEffect(1.6)
                    Text("Connecting").tv(.readout, color: Palette.textTertiary)
                }
            }
        case .failed, .rejected:
            VStack(spacing: Space.m) {
                Image(systemName: "video.slash").font(.system(size: 44)).foregroundStyle(Palette.textTertiary)
                Text("No signal").tv(.readout, color: Palette.textTertiary)
            }
        case .connected:
            EmptyView()
        }
    }

    private var ledColor: Color {
        switch connection.phase {
        case .connected: Palette.live
        case .connecting: Palette.warn
        case .idle, .failed, .rejected: reachability.color
        }
    }

    private var ledLabel: String {
        switch connection.phase {
        case .connected: "Live"
        case .connecting: "Linking"
        case .idle, .failed, .rejected: reachability.label
        }
    }
}
