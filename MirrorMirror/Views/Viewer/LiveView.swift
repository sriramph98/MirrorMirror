import SwiftUI
import AVKit

struct LiveView: View {
    @ObservedObject var connection: CameraConnection
    /// False when opened from the grid, which keeps its own connections alive.
    var ownsConnection = true
    @EnvironmentObject private var hub: ViewerHub
    @State private var previousAudioFocus: String??
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pip = PiPController()
    @State private var showControls = false
    @State private var showExport = false
    @State private var showOverlay = true
    @State private var banner: CameraEvent?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    videoArea(overlayControls: true).ignoresSafeArea()
                } else {
                    // Portrait: chrome above and below the video so nothing covers the picture.
                    VStack(spacing: 0) {
                        topBar.padding(.horizontal, 12).padding(.bottom, 10)
                        videoArea(overlayControls: false)
                            .frame(height: min(geo.size.height * 0.42, geo.size.width * videoAspect))
                        bottomBar.padding(.vertical, 12)
                        Divider()
                        TimelinePanel(connection: connection, onExport: { showExport = true })
                    }
                }
            }
        }
        .statusBarHidden(false)
        .onAppear {
            previousAudioFocus = .some(hub.audioFocus)
            hub.audioFocus = connection.id
            connection.connect()
        }
        .onDisappear {
            if ownsConnection, !pip.isActive { connection.disconnect() }
            hub.audioFocus = previousAudioFocus ?? nil
        }
        .onChange(of: connection.latestEvent) { _, event in
            guard let event else { return }
            withAnimation { banner = event }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if banner == event { withAnimation { banner = nil } }
            }
        }
        .sheet(isPresented: $showControls) {
            CameraControlsSheet(connection: connection)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(connection: connection)
                .presentationDetents([.medium, .large])
        }
    }

    private var videoAspect: CGFloat {
        let size = connection.videoSize
        return size.width > 0 ? size.height / size.width : 9.0 / 16.0
    }

    // MARK: Video + overlays

    private func videoArea(overlayControls: Bool) -> some View {
        ZStack {
            VideoSurface(sink: connection.sink) { view in pip.attach(to: view.displayLayer) }
                .onTapGesture { if overlayControls { withAnimation { showOverlay.toggle() } } }

            phaseOverlay

            VStack {
                if overlayControls && showOverlay { topBar }
                if let banner { eventBanner(banner).padding(.top, 8) }
                Spacer()
                if let toast = connection.toast { ToastView(text: toast).padding(.bottom, 8) }
                if overlayControls && showOverlay { bottomBar }
            }
            .padding(12)
            .transition(.opacity)
        }
        .clipped()
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            OverlayButton(systemName: "chevron.down", size: 40) { dismiss() }
            VStack(alignment: .leading, spacing: 6) {
                Text(connection.camera.name).font(.headline).shadow(radius: 4)
                HStack(spacing: 6) {
                    if connection.playback.isLive {
                        StatusPill(text: "LIVE", color: connection.phase == .connected ? .red : .gray)
                    } else if let date = connection.playback.date {
                        StatusPill(text: Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .standard)
                                                                             : date.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                                   color: Theme.accent, systemImage: "clock.arrow.circlepath")
                    }
                    if connection.phase == .connected {
                        StatusPill(text: connectionDetail, color: .white, systemImage: pathSymbol)
                    }
                }
            }
            Spacer()
            if let status = connection.status {
                VStack(alignment: .trailing, spacing: 6) {
                    StatusPill(text: status.batteryLevel.map { "\(Int($0 * 100))%" } ?? "–",
                               color: status.isCharging ? .green : .white,
                               systemImage: batterySymbol(status.batteryLevel, charging: status.isCharging))
                    if status.isRecording { StatusPill(text: "REC", color: .red) }
                    if status.nightActive { StatusPill(text: "Night", color: Theme.accent, systemImage: "moon.stars.fill") }
                }
            }
        }
    }

    private var connectionDetail: String {
        var parts = [connection.stats.pathLabel]
        if let rtt = connection.stats.roundTrip { parts.append(rtt < 0.001 ? "<1 ms" : "\(Int(rtt * 1000)) ms") }
        return parts.joined(separator: " · ")
    }

    private var pathSymbol: String {
        switch connection.stats.path {
        case .local: "wifi"
        case .direct: "point.3.connected.trianglepath.dotted"
        case .relay: "arrow.triangle.branch"
        case .unknown: "antenna.radiowaves.left.and.right"
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            OverlayButton(systemName: connection.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          isOn: !connection.isListening) { connection.isListening.toggle() }
                .accessibilityLabel(connection.isListening ? "Mute camera audio" : "Unmute camera audio")
            TalkButton(isTalking: connection.isTalking, otherTalker: connection.otherTalker) { on in
                Task { await connection.setTalking(on) }
            }
            .disabled(connection.phase != .connected)
            OverlayButton(systemName: "camera.fill") { connection.takeSnapshot() }
                .accessibilityLabel("Save snapshot")
            if AVPictureInPictureController.isPictureInPictureSupported() {
                OverlayButton(systemName: "pip.enter") { pip.start() }
                    .accessibilityLabel("Picture in picture")
            }
            OverlayButton(systemName: "slider.horizontal.3") { showControls = true }
                .accessibilityLabel("Camera controls")
        }
    }

    private func eventBanner(_ event: CameraEvent) -> some View {
        Button { connection.play(from: event.date.addingTimeInterval(-5)) } label: {
            HStack(spacing: 10) {
                Image(systemName: event.kind.symbol).foregroundStyle(Theme.accent)
                Text(event.label).font(.subheadline.weight(.semibold))
                Text("Replay").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch connection.phase {
        case .connected:
            if !connection.hasVideo { ProgressView().tint(.white) }
        case let .connecting(message):
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        case let .failed(message):
            messageCard(symbol: "wifi.exclamationmark", message: message, action: "Try Again") { connection.connect() }
        case let .rejected(message):
            messageCard(symbol: "lock.fill", message: message, action: nil) {}
        case .idle:
            EmptyView()
        }
    }

    private func messageCard(symbol: String, message: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let action { Button(action, action: perform).buttonStyle(.bordered) }
        }
        .padding(24)
    }
}

/// Tap to start talking, tap again to stop. Shows who else is talking.
private struct TalkButton: View {
    let isTalking: Bool
    let otherTalker: String?
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!isTalking) } label: {
            HStack(spacing: 8) {
                Image(systemName: isTalking ? "mic.fill" : "mic")
                Text(isTalking ? "Talking" : (otherTalker.map { "\($0) talking" } ?? "Talk"))
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isTalking ? .black : .white)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(isTalking ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isTalking ? "Stop talking" : "Talk through camera")
    }
}

// MARK: - Picture in Picture

@MainActor
final class PiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var isActive = false
    private var controller: AVPictureInPictureController?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        DebugSupport.log("viewer", "picture in picture ready")
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
        // Coming back to the app brings the video back inline, like FaceTime.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.controller?.isPictureInPictureActive == true { self?.controller?.stopPictureInPicture() }
            }
        }
    }

    private var activeObserver: NSObjectProtocol?

    func start() { controller?.startPictureInPicture() }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        DebugSupport.log("viewer", "picture in picture started")
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        DebugSupport.log("viewer", "picture in picture stopped")
        Task { @MainActor in self.isActive = false }
    }

    // Live content: no seeking, always "playing".
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
