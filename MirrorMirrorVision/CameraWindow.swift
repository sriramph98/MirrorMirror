import SwiftUI
import MirrorUI

/// One camera in its own window. The picture fills the window; a glass deck floats under it
/// and the timeline opens as a glass panel on the trailing edge.
struct CameraWindow: View {
    let cameraID: String
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var session: VisionSession
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let camera = hub.camera(id: cameraID) {
            CameraWindowContent(connection: hub.connection(for: camera))
                .environmentObject(hub)
                .environmentObject(session)
        } else {
            EmptyState(symbol: "video.slash", title: "Camera removed",
                       message: "This camera is no longer paired with this device.") {
                Button("Close") { dismissWindow() }
                    .buttonStyle(.secondary)
                    .frame(maxWidth: 200)
                    .cardHover(Radius.control)
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

private struct CameraWindowContent: View {
    @ObservedObject var connection: CameraConnection
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var session: VisionSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @State private var showTimeline = false
    @State private var showControls = false
    @State private var showExport = false
    @State private var banner: CameraEvent?
    @State private var bracketFlash = false
    @State private var windowHeight: CGFloat = 540

    var body: some View {
        viewfinder
            .frame(minWidth: 560, minHeight: 315)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
            .ignoresSafeArea()
            .ornament(attachmentAnchor: .scene(.bottom)) { deck }
            .ornament(visibility: showTimeline ? .visible : .hidden,
                      attachmentAnchor: .scene(.trailing), contentAlignment: .leading) {
                VisionTimelinePanel(connection: connection, onClose: { withAnimation(Motion.smooth) { showTimeline = false } },
                                    onExport: { showExport = true })
                    .frame(width: VisionSize.timelineWidth, height: max(VisionSize.timelineMinHeight, windowHeight))
                    .glassBackgroundEffect(in: .rect(cornerRadius: Radius.deck, style: .continuous))
                    .padding(.leading, Space.m)
            }
            .sheet(isPresented: $showExport) {
                VisionExportSheet(connection: connection)
                    .frame(minWidth: 560, minHeight: 620)
            }
            .onAppear {
                showTimeline = session.showTimelineAtLaunch
                showControls = session.showControlsAtLaunch
                showExport = session.showExportAtLaunch
                session.windowOpened(connection.id)
                hub.audioFocus = connection.id
                if connection.phase == .connected { handlePendingReplay() }
            }
            .onDisappear {
                session.windowClosed(connection.id)
                if hub.audioFocus == connection.id { hub.audioFocus = nil }
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
            .onOpenURL { url in session.handle(url, openWindow: openWindow) }
    }

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

    private var hasAudioFocus: Bool { hub.audioFocus == nil || hub.audioFocus == connection.id }

    // MARK: Viewfinder

    private var viewfinder: some View {
        Viewfinder(radius: 0) {
            ZStack {
                VideoSurface(sink: connection.sink)
                if connection.phase != .connected {
                    Palette.frame.opacity(0.72).transition(.opacity)
                }
                phaseOverlay
            }
            .contentShape(Rectangle())
            .onTapGesture { hub.audioFocus = connection.id }
        } topLeading: {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Text(connection.camera.name).type(.navTitle).lineLimit(1)
                    LED(linkColor)
                    ReadoutLine(pathReadout)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(Palette.frame.opacity(0.55), in: .continuous(Radius.chip))
                .accessibilityElement(children: .combine)
                topLeadingReadout
            }
            .padding(Space.s)
        } topTrailing: {
            HStack(spacing: Space.s) {
                topTrailingReadout
                batteryChip
            }
            .padding(Space.s)
        } bottomLeading: {
            bottomLeadingReadout.padding(Space.s)
        } bottomTrailing: {
            bottomTrailingReadout.padding(Space.s)
        }
        .overlay {
            if bracketFlash {
                CornerBrackets(length: 36)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(Space.l)
                    .transition(reduceMotion ? .identity : .scale(scale: 1.06).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if let banner {
                eventBanner(banner)
                    .padding(.top, Space.xxxl + Space.m)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = connection.toast {
                Toast(toast)
                    .padding(.bottom, Space.xxxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: connection.toast)
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
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
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

    @ViewBuilder
    private var bottomLeadingReadout: some View {
        let items = streamReadout
        if !items.isEmpty {
            ReadoutLine(items, color: Palette.textPrimary)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(Palette.frame.opacity(0.55), in: .continuous(Radius.badge))
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
            let audible = connection.isListening && hasAudioFocus
            HStack(spacing: Space.s) {
                if !hasAudioFocus {
                    Text("Sound in another window").type(.readout, color: Palette.textTertiary)
                }
                Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(audible ? Palette.textPrimary : Palette.textTertiary)
                LevelMeter(level: audible ? (connection.stats.audioLevel ?? 0) : 0, segments: 12)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Palette.frame.opacity(0.55), in: .continuous(Radius.badge))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera sound")
            .accessibilityValue(audible ? "\(Int((connection.stats.audioLevel ?? 0) * 100)) percent" : "Muted")
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
            .pillHover()
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
                Button("Try again") { connection.connect() }.buttonStyle(.pill(isOn: true)).pillHover()
            }
        case let .rejected(message):
            PhaseMessage(symbol: "lock.fill", title: "Not allowed", message: message) { EmptyView() }
        case .idle:
            EmptyView()
        }
    }

    // MARK: Deck

    private var deck: some View {
        HStack(spacing: Space.l) {
            speakerTool
            Button { connection.takeSnapshot() } label: { Image(systemName: "camera") }
                .buttonStyle(.tool(size: VisionSize.tool))
                .toolHover()
                .accessibilityLabel("Save snapshot")
            Button { showControls = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.tool(isOn: showControls, size: VisionSize.tool))
                .toolHover()
                .accessibilityLabel("Camera controls")
                .popover(isPresented: $showControls, arrowEdge: .bottom) {
                    VisionControlsPanel(connection: connection)
                        .frame(width: 460, height: 640)
                }

            talkShutter.padding(.horizontal, Space.s)

            rewindOrLive
            Button { withAnimation(Motion.smooth) { showTimeline.toggle() } } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            .buttonStyle(.tool(isOn: showTimeline, size: VisionSize.tool))
            .toolHover()
            .accessibilityLabel("Timeline")
            .accessibilityValue(showTimeline ? "Shown" : "Hidden")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .glassBackgroundEffect(in: .capsule)
        .simultaneousGesture(TapGesture().onEnded { hub.audioFocus = connection.id })
    }

    private var speakerTool: some View {
        Button {
            if !hasAudioFocus {
                hub.audioFocus = connection.id
                connection.isListening = true
            } else {
                connection.isListening.toggle()
            }
        } label: {
            Image(systemName: connection.isListening && hasAudioFocus ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        .buttonStyle(.tool(isOn: !(connection.isListening && hasAudioFocus), size: VisionSize.tool))
        .toolHover()
        .accessibilityLabel("Camera sound")
        .accessibilityValue(connection.isListening && hasAudioFocus ? "On" : "Muted")
    }

    private var talkShutter: some View {
        VStack(spacing: Space.xs) {
            ShutterButton(isActive: connection.isTalking) {
                Task { await connection.setTalking(!connection.isTalking) }
            } label: {
                Image(systemName: connection.isTalking ? "mic.fill" : "mic")
            }
            .toolHover()
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

    @ViewBuilder
    private var rewindOrLive: some View {
        if connection.playback.isLive {
            Button { connection.play(from: Date().addingTimeInterval(-60)) } label: {
                Image(systemName: "gobackward.60")
            }
            .buttonStyle(.tool(size: VisionSize.tool))
            .toolHover()
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
            .pillHover()
            .accessibilityLabel("Back to live")
        }
    }
}

// MARK: - Phase overlays

/// Connecting: a readout line with a slow scanning bar underneath.
struct ActivityReadout: View {
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

/// Failed / rejected: compact empty state that fits inside the picture.
struct PhaseMessage<Actions: View>: View {
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
