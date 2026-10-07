import SwiftUI
import MirrorUI

/// The wall: every paired camera at once. Audio plays from one camera at a time.
/// Full screen on iPhone (with a close button); embedded in the iPad detail column.
struct GridView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// True inside the iPad split view: no close button.
    var embedded = false
    /// Opens a camera in place (iPad). When nil the wall presents the live view itself.
    var onOpen: ((PairedCamera) -> Void)? = nil

    @State private var focused: PairedCamera?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("All cameras", leadingSymbol: embedded ? nil : "xmark", leadingAction: embedded ? nil : { dismiss() })
            HStack(spacing: Space.s) {
                Text("\(hub.cameras.count) \(hub.cameras.count == 1 ? "camera" : "cameras")").type(.caps)
                Spacer(minLength: Space.s)
                Image(systemName: audioFocused ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(audioFocused ? Palette.accent : Palette.textTertiary)
                ReadoutLine([audioReadout], color: audioFocused ? Palette.textPrimary : Palette.textTertiary)
            }
            .padding(.horizontal, Space.l + Space.xs)
            .padding(.bottom, Space.m)
            .accessibilityElement(children: .combine)
            GeometryReader { geo in
                let columns = columnCount(for: geo.size)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m), count: columns),
                              spacing: Space.m) {
                        ForEach(hub.cameras) { camera in
                            WallTile(connection: hub.connection(for: camera), audioOn: hub.audioFocus == camera.id) {
                                hub.audioFocus = hub.audioFocus == camera.id ? "" : camera.id
                            } onOpen: {
                                open(camera)
                            }
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, Space.l)
                }
                .scrollIndicators(.hidden)
            }
        }
        .canvasBackground(Palette.frame)
        .preferredColorScheme(.dark)
        .task {
            // Deferred to a task so a live view being replaced by the wall has torn down first.
            WallHandoff.keepConnected = nil
            // Muted until a tile is chosen; "" means no camera has audio.
            hub.audioFocus = ""
            hub.cameras.forEach { hub.connection(for: $0).connect() }
        }
        .onDisappear {
            let keep = WallHandoff.keepConnected
            for camera in hub.cameras where camera.id != keep { hub.connection(for: camera).disconnect() }
            hub.audioFocus = nil
        }
        .fullScreenCover(item: $focused) { camera in
            LiveView(connection: hub.connection(for: camera), ownsConnection: false, onClose: { focused = nil })
        }
    }

    private var audioFocused: Bool { hub.audioFocus.map { !$0.isEmpty } ?? false }

    private var audioReadout: String {
        guard let id = hub.audioFocus, !id.isEmpty, let camera = hub.camera(id: id) else { return "Audio muted" }
        return "Audio · \(camera.name)"
    }

    private func open(_ camera: PairedCamera) {
        if let onOpen {
            WallHandoff.keepConnected = camera.id
            onOpen(camera)
        } else {
            focused = camera
        }
    }

    /// 1 column on compact portrait, 2 in landscape; 2–3 on iPad by width.
    private func columnCount(for size: CGSize) -> Int {
        let wanted: Int
        if sizeClass == .regular {
            wanted = size.width > ControlSize.readableWidth * 1.6 ? 3 : 2
        } else {
            wanted = size.width > size.height ? 2 : 1
        }
        return max(1, min(wanted, hub.cameras.count))
    }
}

private struct WallTile: View {
    @ObservedObject var connection: CameraConnection
    let audioOn: Bool
    let onToggleAudio: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Viewfinder(radius: Radius.panel) {
                VideoSurface(sink: connection.sink, fill: true)
                phaseOverlay
            } topLeading: {
                Text(connection.camera.name).type(.caps, color: Palette.textPrimary)
                    .shadow(color: Palette.frame.opacity(0.6), radius: Space.xs)
            } topTrailing: {
                HStack(spacing: Space.s) {
                    if connection.status?.isRecording == true { Badge("Rec", style: .recording) }
                    LED(ledColor, label: ledLabel, pulsing: connection.phase == .connected)
                        .shadow(color: Palette.frame.opacity(0.6), radius: Space.xs)
                }
            } bottomLeading: {
                if let event = connection.latestEvent, Date().timeIntervalSince(event.date) < 30 {
                    Badge(event.kind.title, style: .accent)
                        .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
        .buttonStyle(CardPressStyle())
        .overlay(alignment: .bottomTrailing) {
            Button(action: onToggleAudio) {
                Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.tool(isOn: audioOn))
            .padding(Space.s)
            .accessibilityLabel("Audio from \(connection.camera.name)")
            .accessibilityValue(audioOn ? "On" : "Muted")
        }
        .focusBrackets(audioOn ? Palette.accent : .clear, length: Space.xl, inset: -Space.xs)
        .animation(Motion.smooth, value: audioOn)
        .accessibilityLabel("\(connection.camera.name), \(ledLabel)")
        .accessibilityHint("Opens the live view")
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch connection.phase {
        case .connecting, .idle:
            if !connection.hasVideo {
                VStack(spacing: Space.s) {
                    ProgressView().tint(Palette.textSecondary)
                    Text("Connecting").type(.readout, color: Palette.textTertiary)
                }
            }
        case .failed, .rejected:
            VStack(spacing: Space.s) {
                Image(systemName: "video.slash").font(.title2).foregroundStyle(Palette.textTertiary)
                Text("No signal").type(.readout, color: Palette.textTertiary)
            }
        case .connected:
            EmptyView()
        }
    }

    private var ledColor: Color {
        switch connection.phase {
        case .connected: Palette.live
        case .connecting, .idle: Palette.warn
        case .failed, .rejected: Palette.textTertiary
        }
    }

    private var ledLabel: String {
        switch connection.phase {
        case .connected: "Live"
        case .connecting, .idle: "Linking"
        case .failed, .rejected: "Offline"
        }
    }
}
