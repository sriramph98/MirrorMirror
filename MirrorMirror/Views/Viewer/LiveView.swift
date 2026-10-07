import SwiftUI
import AVKit
import MirrorUI

/// Watching one camera (Halide-style): header, viewfinder with corner readouts, a deck of tools
/// around the Talk shutter, and the recordings timeline.
///
/// - iPhone portrait: header, viewfinder, deck, timeline below.
/// - iPhone landscape: full-bleed picture with an overlay deck (tap to hide).
/// - iPad landscape (≥ 900 pt, wider than tall): picture and deck top-left, a 380 pt timeline column right.
/// - iPad portrait / sidebar open / Slide Over: stacked like iPhone portrait, picture up to 55 % of the height.
struct LiveView: View {
    @ObservedObject var connection: CameraConnection
    /// False when opened from the grid, which keeps its own connections alive.
    var ownsConnection: Bool
    /// Close action for full-screen presentation. Nil when embedded (iPad split view): no close button.
    var onClose: (() -> Void)?

    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pip = PiPController()
    @State private var previousAudioFocus: String??
    @State private var showControls = false
    @State private var showExport = false
    @State private var showChrome = true
    @State private var banner: CameraEvent?
    @State private var bracketFlash = false

    init(connection: CameraConnection, ownsConnection: Bool = true, onClose: (() -> Void)? = nil) {
        _connection = ObservedObject(wrappedValue: connection)
        self.ownsConnection = ownsConnection
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                let size = geo.size
                if verticalSizeClass == .compact && size.width > size.height {
                    // iPhone landscape (any size, including Max which reports regular width).
                    landscapeLayout(geo.safeAreaInsets)
                } else if sizeClass == .regular && size.width >= 900 && size.width > size.height {
                    // iPad landscape: picture + deck left, timeline column right.
                    wideLayout(size)
                } else if sizeClass == .regular {
                    // iPad portrait, sidebar open, Slide Over: stacked, roomier picture.
                    stackedLayout(size, pictureShare: 0.55, deckWidth: 520)
                } else if size.width > size.height {
                    landscapeLayout(geo.safeAreaInsets)
                } else {
                    stackedLayout(size, pictureShare: 0.4, deckWidth: nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Palette.frame.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            previousAudioFocus = .some(hub.audioFocus)
            hub.audioFocus = connection.id
            connection.connect()
            // A grid-owned connection may already be up, so the phase change below never fires.
            if connection.phase == .connected { handlePendingReplay() }
        }
        .onDisappear {
            if ownsConnection, !pip.isActive { connection.disconnect() }
            hub.audioFocus = previousAudioFocus ?? nil
        }
        .onChange(of: connection.phase) { _, phase in
            if phase == .connected { handlePendingReplay() }
        }
        .onChange(of: connection.latestEvent) { _, event in
            guard let event else { return }
            withAnimation(Motion.smooth) { banner = event }
            flashBrackets()
            Task {
                try? await Task.sleep(for: .seconds(5))
                if banner == event { withAnimation(Motion.fade) { banner = nil } }
            }
        }
        .sheet(isPresented: $showControls) {
            CameraControlsSheet(connection: connection)
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.canvas)
                .presentationCornerRadius(Radius.deck)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(connection: connection)
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.canvas)
                .presentationCornerRadius(Radius.deck)
        }
    }

    /// Opened from an event notification: jump to a few seconds before it.
    private func handlePendingReplay() {
        guard let replay = hub.pendingReplay, replay.cameraID == connection.id else { return }
        hub.pendingReplay = nil
        connection.refreshTimeline()
        connection.play(from: replay.date.addingTimeInterval(-5))
    }

    private func flashBrackets() {
        if reduceMotion {
            bracketFlash = true
        } else {
            withAnimation(Motion.snappy) { bracketFlash = true }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(reduceMotion ? nil : Motion.fade) { bracketFlash = false }
        }
    }

    /// Width over height of the incoming picture.
    private var videoRatio: CGFloat {
        let size = connection.videoSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    // MARK: Layouts

    /// Header, full-width picture (capped to a share of the height), deck, then the scrolling timeline.
    private func stackedLayout(_ size: CGSize, pictureShare: CGFloat, deckWidth: CGFloat?) -> some View {
        VStack(spacing: Space.m) {
            header.padding(.horizontal, Space.l)
            viewfinder(radius: Radius.viewfinder)
                .frame(height: min(size.height * pictureShare, (size.width - Space.s * 2) / videoRatio))
                .padding(.horizontal, Space.s)
            deck
                .frame(maxWidth: deckWidth ?? .infinity)
                .padding(.horizontal, Space.xl)
            TimelinePanel(connection: connection, onExport: { showExport = true })
        }
        .padding(.top, Space.xs)
    }

    private static let timelineWidth: CGFloat = 380
    /// Rough height of the deck (tool row, shutter and its caption) for sizing the picture above it.
    private static let deckHeight: CGFloat = ControlSize.tool + ControlSize.shutter + Space.l + Space.xl * 2

    private func wideLayout(_ size: CGSize) -> some View {
        let column = max(1, size.width - Space.l * 3 - Self.timelineWidth)
        let maxPicture = max(1, size.height - Self.deckHeight - ControlSize.tool - Space.l * 3)
        return HStack(alignment: .top, spacing: Space.l) {
            // Picture fills the column's width, top-aligned, with the deck directly under it.
            VStack(spacing: Space.l) {
                header
                viewfinder(radius: Radius.viewfinder)
                    .frame(width: column, height: min(column / videoRatio, maxPicture))
                deck.frame(maxWidth: 520)
                Spacer(minLength: 0)
            }
            .frame(width: column)
            TimelinePanel(connection: connection, onExport: { showExport = true })
                .frame(width: Self.timelineWidth)
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
    }

    private func landscapeLayout(_ insets: EdgeInsets) -> some View {
        let inset = EdgeInsets(top: max(insets.top, Space.s), leading: max(insets.leading, Space.s),
                               bottom: max(insets.bottom, Space.s), trailing: max(insets.trailing, Space.s))
        return viewfinder(radius: 0, insets: inset, overlayChrome: true)
            .ignoresSafeArea()
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }

    // MARK: Header

    private var header: some View { header(showsBattery: true) }

    private func header(showsBattery: Bool) -> some View {
        HStack(spacing: Space.m) {
            if let onClose {
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .buttonStyle(.tool())
                    .accessibilityLabel("Close")
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(connection.camera.name).type(.navTitle).lineLimit(1)
                HStack(spacing: Space.xs + Space.xxs) {
                    LED(linkColor)
                    ReadoutLine(pathReadout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection")
                .accessibilityValue(pathReadout.joined(separator: ", "))
            }
            Spacer(minLength: Space.s)
            if showsBattery { batteryChip }
        }
    }

    @ViewBuilder
    private var batteryChip: some View {
        if let status = connection.status {
            let level = status.batteryLevel
            StatChip(level.map { "\(Int($0 * 100))%" } ?? "–",
                     tag: level == nil && !status.isCharging ? "Batt" : nil,
                     symbol: level == nil && !status.isCharging ? nil : batterySymbol(level, charging: status.isCharging),
                     tint: status.isCharging ? Palette.ok : ((level ?? 1) < 0.2 ? Palette.warn : Palette.textPrimary))
                .accessibilityLabel("Camera battery")
                .accessibilityValue(level.map { "\(Int($0 * 100)) percent\(status.isCharging ? ", charging" : "")" } ?? "Unknown")
        }
    }

    private var pathReadout: [String] {
        switch connection.phase {
        case .connected:
            var parts = [connection.stats.path.readoutLabel]
            if let rtt = connection.stats.roundTrip { parts.append(rtt < 0.001 ? "<1 ms" : "\(Int(rtt * 1000)) ms") }
            return parts
        case .connecting: return ["Connecting"]
        case .failed: return ["Offline"]
        case .rejected: return ["Not allowed"]
        case .idle: return ["Idle"]
        }
    }

    private var linkColor: Color {
        switch connection.phase {
        case .connected: connection.stats.path == .relay ? Palette.warn : Palette.ok
        case .connecting: Palette.warn
        case .failed, .rejected: Palette.live
        case .idle: Palette.textTertiary
        }
    }

    // MARK: Viewfinder

    private func viewfinder(radius: CGFloat, insets: EdgeInsets = EdgeInsets(), overlayChrome: Bool = false) -> some View {
        let chrome = overlayChrome && showChrome
        return Viewfinder(radius: radius) {
            ZStack {
                VideoSurface(sink: connection.sink) { view in pip.attach(to: view.displayLayer) }
                if connection.phase != .connected {
                    // Dim the last frame so it never reads as live.
                    Palette.frame.opacity(0.72).transition(.opacity)
                }
                phaseOverlay
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard overlayChrome else { return }
                withAnimation(Motion.fade) { showChrome.toggle() }
            }
        } topLeading: {
            VStack(alignment: .leading, spacing: Space.m) {
                if chrome { header(showsBattery: false).fixedSize().transition(.opacity) }
                topLeadingReadout
            }
            .padding(.top, insets.top).padding(.leading, insets.leading)
        } topTrailing: {
            HStack(spacing: Space.s) {
                topTrailingReadout
                if chrome { batteryChip.transition(.opacity) }
            }
            .padding(.top, insets.top).padding(.trailing, insets.trailing)
        } bottomLeading: {
            bottomLeadingReadout
                .padding(.bottom, insets.bottom).padding(.leading, insets.leading)
        } bottomTrailing: {
            bottomTrailingReadout
                .padding(.bottom, insets.bottom).padding(.trailing, insets.trailing)
        }
        .overlay {
            if bracketFlash {
                CornerBrackets(length: 30)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(Space.s)
                    .padding(insets)
                    .transition(reduceMotion ? .identity : .scale(scale: 1.06).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) {
            if chrome {
                landscapeRail
                    .padding(.trailing, insets.trailing + Space.s)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: Space.m) {
                if let toast = connection.toast {
                    Toast(toast).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if chrome {
                    toolRow(spacing: Space.l).transition(.opacity)
                }
            }
            .padding(.bottom, insets.bottom + (overlayChrome ? Space.m : Space.xxxl))
            .animation(Motion.smooth, value: connection.toast)
        }
        .overlay(alignment: .top) {
            if let banner {
                eventBanner(banner)
                    .padding(.top, insets.top + (overlayChrome ? Space.m : Space.xxxl))
                    .padding(.horizontal, Space.l)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .accessibilityAction(named: showChrome ? "Hide controls" : "Show controls") {
            if overlayChrome { showChrome.toggle() }
        }
    }

    @ViewBuilder
    private var topLeadingReadout: some View {
        if !connection.playback.isLive, let date = connection.playback.date {
            let rate = connection.playback.rate
            Badge(([connection.playback.isPlaying ? "Playback" : "Paused", date.timelineStamp] + (rate == 1 ? [] : ["\(Int(rate))×"]))
                .joined(separator: " "), style: .accent)
                .accessibilityLabel("Playing back from \(date.formatted(date: .abbreviated, time: .standard))")
        } else {
            let live = connection.phase == .connected
            LED(live ? Palette.live : Palette.textTertiary, label: live ? "Live" : "Off air", pulsing: live)
                .id(live)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs + Space.xxs)
                .background(Palette.frame.opacity(0.55), in: .continuous(Radius.badge))
        }
    }

    @ViewBuilder
    private var topTrailingReadout: some View {
        if let status = connection.status, connection.phase == .connected {
            HStack(spacing: Space.xs) {
                if status.nightActive { Badge("Night", style: .filled) }
                if status.effectiveQuality != status.quality { Badge("Hot", style: .outline) }
                if status.isRecording { Badge("Rec", style: .recording) }
            }
        }
    }

    @ViewBuilder
    private var bottomLeadingReadout: some View {
        let items = streamReadout
        if !items.isEmpty {
            ReadoutLine(items, color: Palette.textPrimary)
                .shadow(color: Palette.frame.opacity(0.9), radius: 3)
                .accessibilityLabel("Stream")
                .accessibilityValue(items.joined(separator: ", "))
        }
    }

    private var streamReadout: [String] {
        guard connection.phase == .connected else { return [] }
        let stats = connection.stats
        var items: [String] = []
        if let w = stats.width, let h = stats.height { items.append("\(min(w, h))") }
        if let fps = stats.fps { items.append("\(Int(fps.rounded())) fps") }
        if let bitrate = stats.bitrate {
            items.append(bitrate >= 1_000_000 ? String(format: "%.1f Mbps", bitrate / 1_000_000) : "\(Int(bitrate / 1000)) kbps")
        }
        return items
    }

    @ViewBuilder
    private var bottomTrailingReadout: some View {
        if connection.phase == .connected {
            HStack(spacing: Space.s) {
                Image(systemName: connection.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(connection.isListening ? Palette.textPrimary : Palette.textTertiary)
                LevelMeter(level: connection.isListening ? (connection.stats.audioLevel ?? 0) : 0, segments: 10)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + Space.xxs)
            .background(Palette.frame.opacity(0.55), in: .continuous(Radius.badge))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera sound")
            .accessibilityValue(connection.isListening ? "\(Int((connection.stats.audioLevel ?? 0) * 100)) percent" : "Muted")
        }
    }

    private func eventBanner(_ event: CameraEvent) -> some View {
        HStack(spacing: Space.s) {
            Toast(event.label, symbol: event.kind.symbol)
            Button {
                connection.play(from: event.date.addingTimeInterval(-5))
                withAnimation(Motion.fade) { banner = nil }
            } label: {
                Text("Replay")
            }
            .buttonStyle(.pill(isOn: true))
            .accessibilityLabel("Replay \(event.label)")
        }
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch connection.phase {
        case .connected:
            if !connection.hasVideo { ActivityReadout(text: "Waiting for video") }
        case let .connecting(message):
            ActivityReadout(text: message)
        case let .failed(message):
            PhaseMessage(symbol: "wifi.exclamationmark", title: "Can't reach camera", message: message) {
                Button("Try again") { connection.connect() }.buttonStyle(.pill(isOn: true))
            }
        case let .rejected(message):
            PhaseMessage(symbol: "lock.fill", title: "Not allowed", message: message) { EmptyView() }
        case .idle:
            EmptyView()
        }
    }

    // MARK: Deck

    private var deck: some View {
        VStack(spacing: Space.l) {
            toolRow(spacing: nil)
            HStack(alignment: .center, spacing: 0) {
                latestEventButton.frame(width: 96, alignment: .leading)
                Spacer(minLength: Space.s)
                talkShutter
                Spacer(minLength: Space.s)
                rewindOrLive.frame(width: 96, alignment: .trailing)
            }
        }
    }

    /// Speaker, snapshot, PiP, controls. Evenly spread in the deck; packed when overlaid.
    private func toolRow(spacing: CGFloat?) -> some View {
        HStack(spacing: spacing ?? 0) {
            speakerTool
            if spacing == nil { Spacer(minLength: Space.s) }
            Button { connection.takeSnapshot() } label: { Image(systemName: "camera") }
                .buttonStyle(.tool())
                .accessibilityLabel("Save snapshot")
            if AVPictureInPictureController.isPictureInPictureSupported() {
                if spacing == nil { Spacer(minLength: Space.s) }
                Button { pip.start() } label: { Image(systemName: "pip.enter") }
                    .buttonStyle(.tool(isOn: pip.isActive))
                    .accessibilityLabel("Picture in picture")
            }
            if spacing == nil { Spacer(minLength: Space.s) }
            Button { showControls = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.tool())
                .accessibilityLabel("Camera controls")
        }
    }

    private var speakerTool: some View {
        // Accent when muted: the state that differs from normal is the one that lights up.
        Button { connection.isListening.toggle() } label: {
            Image(systemName: connection.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        .buttonStyle(.tool(isOn: !connection.isListening))
        .accessibilityLabel("Camera sound")
        .accessibilityValue(connection.isListening ? "On" : "Muted")
        .accessibilityHint(connection.isListening ? "Mutes the camera's microphone on this device" : "Plays the camera's microphone")
    }

    private var talkShutter: some View {
        VStack(spacing: Space.xs) {
            ShutterButton(isActive: connection.isTalking) {
                Task { await connection.setTalking(!connection.isTalking) }
            } label: {
                Image(systemName: connection.isTalking ? "mic.fill" : "mic")
            }
            .disabled(connection.phase != .connected)
            .opacity(connection.phase == .connected ? 1 : 0.4)
            .accessibilityLabel(connection.isTalking ? "Stop talking" : "Talk through camera")
            .accessibilityValue(connection.otherTalker.map { "\($0) is talking" } ?? "")

            Text(talkCaption)
                .type(.caps, color: connection.isTalking ? Palette.accent : (connection.otherTalker != nil ? Palette.warn : Palette.textSecondary))
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var talkCaption: String {
        if connection.isTalking { return "Talking" }
        if let other = connection.otherTalker { return "\(other) talking" }
        return "Talk"
    }

    private var latestEvent: CameraEvent? { connection.events.max { $0.date < $1.date } }

    @ViewBuilder
    private var latestEventButton: some View {
        if let event = latestEvent {
            Button {
                if connection.phase == .connected { connection.play(from: event.date.addingTimeInterval(-5)) }
            } label: {
                ZStack {
                    Palette.raised
                    if let image = connection.thumbnail(for: event) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: event.kind.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(event.kind.timelineTint)
                    }
                }
                .frame(width: ControlSize.thumbnail, height: ControlSize.thumbnail)
                .clipShape(.continuous(Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(event.kind.timelineTint).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Palette.frame, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replay latest event")
            .accessibilityValue("\(event.label), \(event.date.formatted(date: .omitted, time: .shortened))")
        } else {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .background(Palette.surface, in: .continuous(Radius.chip))
                .frame(width: ControlSize.thumbnail, height: ControlSize.thumbnail)
                .overlay(Image(systemName: "bell.slash").font(.footnote).foregroundStyle(Palette.textTertiary))
                .accessibilityLabel("No events yet")
        }
    }

    @ViewBuilder
    private var rewindOrLive: some View {
        if connection.playback.isLive {
            Button { connection.play(from: Date().addingTimeInterval(-60)) } label: {
                Image(systemName: "gobackward.60")
            }
            .buttonStyle(.tool(size: ControlSize.toolLarge))
            .disabled(connection.segments.isEmpty || connection.phase != .connected)
            .opacity(connection.segments.isEmpty || connection.phase != .connected ? 0.4 : 1)
            .accessibilityLabel("Back 60 seconds")
        } else {
            Button { connection.goLive() } label: {
                HStack(spacing: Space.xs) {
                    Circle().fill(Palette.live).frame(width: 6, height: 6)
                    Text("Live")
                }
            }
            .buttonStyle(.pill(isOn: true))
            .accessibilityLabel("Back to live")
        }
    }

    /// Landscape overlay: thumbnail, Talk and LIVE / −60 stacked on the trailing edge.
    private var landscapeRail: some View {
        VStack(spacing: Space.l) {
            latestEventButton
            talkShutter
            rewindOrLive
        }
        .padding(.vertical, Space.l)
        .padding(.horizontal, Space.m)
        .background(Palette.frame.opacity(0.55), in: .continuous(Radius.deck))
    }
}

// MARK: - Phase overlays

/// Connecting: a readout line with a slow scanning bar underneath.
private struct ActivityReadout: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        VStack(spacing: Space.m) {
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.raised)
                Capsule().fill(Palette.accent)
                    .frame(width: 28)
                    .offset(x: reduceMotion ? 46 : (phase ? 92 : 0))
            }
            .frame(width: 120, height: 3)
            .clipShape(Capsule())
            Text(text).type(.readout, color: Palette.textSecondary).multilineTextAlignment(.center)
        }
        .padding(Space.l)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Failed / rejected: compact EmptyState that fits inside a small viewfinder.
private struct PhaseMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 48, height: 48)
                .focusBrackets(Palette.textTertiary, length: 10, lineWidth: 1.5, inset: 0)
            Text(title).type(.headline)
            Text(message).type(.footnote, color: Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            actions().padding(.top, Space.xs)
        }
        .padding(Space.l)
        .frame(maxWidth: 360)
    }
}

extension LinkStats.Path {
    /// "P2P", "LOCAL", "RELAY" for the header readout.
    var readoutLabel: String {
        switch self {
        case .local: "Local"
        case .direct: "P2P"
        case .relay: "Relay"
        case .unknown: "Linking"
        }
    }
}

// MARK: - Picture in Picture

@MainActor
final class PiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Rotating swaps the video surface; follow the new layer unless PiP is running from the old one.
        if controller != nil {
            guard attachedLayer !== layer, !isActive else { return }
            controller = nil
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        DebugSupport.log("viewer", "picture in picture ready")
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
        attachedLayer = layer
        // Coming back to the app brings the video back inline, like FaceTime.
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if self?.controller?.isPictureInPictureActive == true { self?.controller?.stopPictureInPicture() }
                }
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
