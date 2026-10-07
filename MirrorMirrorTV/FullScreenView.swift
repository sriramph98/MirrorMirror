import SwiftUI
import MirrorUI

/// One camera edge to edge. The overlay (corner readouts and the control bar) appears on any
/// remote movement and hides after four seconds. Swipe left/right to change camera, Menu for
/// the wall, Play/Pause to pause a replay.
struct FullScreenView: View {
    let cameraID: String
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var focus: Focus?
    @State private var overlayVisible = false
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: TimelinePanelTV.Tab?
    @State private var switchedName: String?

    enum Focus: Hashable {
        case stage
        case bar(Control)
        case panel
    }

    enum Control: Hashable, CaseIterable {
        case live, rewind, speed, timeline, events, listen, mute
    }

    private static let hideDelay: Duration = .seconds(4)

    private var camera: PairedCamera? { hub.camera(id: cameraID) }

    var body: some View {
        if let camera {
            FullScreenBody(connection: hub.connection(for: camera), camera: camera, focus: $focus,
                           overlayVisible: $overlayVisible, panel: $panel, switchedName: $switchedName,
                           showOverlay: showOverlay, hideOverlay: hideOverlay, switchCamera: switchCamera)
                .onAppear {
                    hub.audioFocus = camera.id
                    hub.connection(for: camera).connect()
                    focus = .stage
                    if TVDebug.screen == "timeline" || TVDebug.screen == "events" {
                        openPanel(TVDebug.screen == "events" ? .events : .timeline)
                    } else if TVDebug.screen == "full" {
                        showOverlay(focusBar: true)
                    }
                }
                .onDisappear {
                    hideTask?.cancel()
                    // Back to the wall: it reconnects every tile itself, so keep this one warm.
                    if router.screen != .wall { hub.connection(for: camera).disconnect() }
                }
                .onExitCommand {
                    if panel != nil {
                        closePanel()
                    } else if overlayVisible {
                        hideOverlay()
                    } else {
                        router.screen = .wall
                    }
                }
                .onChange(of: focus) { _, _ in
                    if overlayVisible, panel == nil { scheduleHide() }
                }
                .onChange(of: cameraID) { _, id in
                    // Same screen, another camera (alert Replay, Top Shelf): bring it up like a fresh appearance.
                    guard let next = hub.camera(id: id) else { return }
                    hub.audioFocus = next.id
                    hub.connection(for: next).connect()
                    if panel != nil { closePanel() }
                }
                #if DEBUG
                .onChange(of: router.debugCommand) { _, command in
                    guard let command else { return }
                    switch command {
                    case "overlay": showOverlay(focusBar: true)
                    case "hide": hideOverlay()
                    case "timeline": openPanel(.timeline)
                    case "events": openPanel(.events)
                    case "close": closePanel()
                    case "next": switchCamera(1)
                    case "prev": switchCamera(-1)
                    case "rewind": hub.connection(for: camera).play(from: Date().addingTimeInterval(-60))
                    case "live": hub.connection(for: camera).goLive()
                    default:
                        if command.hasPrefix("bar/"), let control = Control.allCases.first(where: { "\($0)" == String(command.dropFirst(4)) }) {
                            showOverlay(focusBar: false)
                            focus = .bar(control)
                        }
                    }
                }
                #endif
        } else {
            Color.clear.onAppear { router.screen = .wall }
        }
    }

    // MARK: Overlay timing

    private func showOverlay(focusBar: Bool) {
        withAnimation(reduceMotion ? nil : Motion.fade) { overlayVisible = true }
        if focusBar { focus = .bar(.live) }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, panel == nil else { return }
            hideOverlay()
        }
    }

    private func hideOverlay() {
        hideTask?.cancel()
        withAnimation(reduceMotion ? nil : Motion.fade) { overlayVisible = false }
        focus = .stage
    }

    private func openPanel(_ tab: TimelinePanelTV.Tab) {
        hideTask?.cancel()
        withAnimation(reduceMotion ? nil : Motion.smooth) {
            overlayVisible = true
            panel = tab
        }
        focus = .panel
    }

    private func closePanel() {
        withAnimation(reduceMotion ? nil : Motion.smooth) { panel = nil }
        focus = .bar(.timeline)
        scheduleHide()
    }

    /// Swipe left/right: previous / next camera, wrapping. The old link is dropped once the new one is up.
    private func switchCamera(_ delta: Int) {
        let cameras = hub.cameras
        guard cameras.count > 1, let index = cameras.firstIndex(where: { $0.id == cameraID }) else { return }
        let next = cameras[(index + delta + cameras.count) % cameras.count]
        let previous = cameras[index]
        hub.connection(for: next).connect()
        hub.audioFocus = next.id
        router.keepConnected = next.id
        router.screen = .full(cameraID: next.id)
        withAnimation(reduceMotion ? nil : Motion.fade) { switchedName = next.name }
        Task {
            try? await Task.sleep(for: .seconds(2))
            hub.connection(for: previous).disconnect()
            if switchedName == next.name { withAnimation(Motion.fade) { switchedName = nil } }
        }
    }
}

// MARK: - Body

/// Split out so the connection can be observed with `@ObservedObject`.
private struct FullScreenBody: View {
    @ObservedObject var connection: CameraConnection
    let camera: PairedCamera
    var focus: FocusState<FullScreenView.Focus?>.Binding
    @Binding var overlayVisible: Bool
    @Binding var panel: TimelinePanelTV.Tab?
    @Binding var switchedName: String?
    let showOverlay: (Bool) -> Void
    let hideOverlay: () -> Void
    let switchCamera: (Int) -> Void

    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rates: [Double] = [1, 2, 4, 8]

    var body: some View {
        ZStack {
            VideoSurface(sink: connection.sink)
                .ignoresSafeArea()
            if connection.phase != .connected { Palette.frame.opacity(0.6).ignoresSafeArea() }

            // The stage: takes focus while the overlay is hidden, so swipes reach us.
            Button { showOverlay(true) } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.tvStage)
                .focusable(!overlayVisible)
                .focused(focus, equals: .stage)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: switchCamera(-1)
                    case .right: switchCamera(1)
                    default: showOverlay(true)
                    }
                }
                .ignoresSafeArea()
                .accessibilityLabel(camera.name)
                .accessibilityHint("Shows the controls. Swipe left or right for another camera.")

            phaseOverlay
                .padding(.trailing, panel == nil ? 0 : TVSize.panelWidth + Space.xl)

            if overlayVisible || switchedName != nil {
                TVScrim().transition(.opacity)
            }
            if overlayVisible {
                // With the side panel open the readouts and bar keep to the space left of it.
                corners
                    .padding(.trailing, panel == nil ? 0 : TVSize.panelWidth + Space.xl)
                    .transition(.opacity)
            }
            if let switchedName, !overlayVisible {
                Text(switchedName).tv(.navTitle)
                    .padding(.horizontal, Space.xxl).padding(.vertical, Space.l)
                    .background(Palette.frame.opacity(0.6), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, TVSize.margin)
                    .transition(.opacity)
            }
            if let toast = connection.toast {
                Text(toast).tv(.callout)
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.l)
                    .background(Palette.raised, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            if let tab = panel {
                TimelinePanelTV(connection: connection, tab: tab, focus: focus) {
                    withAnimation(reduceMotion ? nil : Motion.smooth) { panel = nil }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onPlayPauseCommand {
            if !connection.playback.isLive {
                connection.togglePause()
            }
            showOverlay(false)
        }
        .onChange(of: connection.phase) { _, phase in
            if phase == .connected { handlePendingReplay() }
        }
        .onChange(of: router.pendingReplay) { _, replay in
            // Already connected and watching this camera when the request lands.
            if replay != nil, connection.phase == .connected { handlePendingReplay() }
        }
        .onAppear {
            if connection.phase == .connected { handlePendingReplay() }
        }
        .animation(Motion.smooth, value: connection.toast)
        .canvasBackground(Palette.frame)
    }

    /// Opened from an alert or Top Shelf: jump to a few seconds before the event.
    private func handlePendingReplay() {
        guard let replay = router.pendingReplay, replay.cameraID == connection.id else { return }
        router.pendingReplay = nil
        connection.refreshTimeline()
        connection.play(from: replay.date)
        // Show what's happening: picture first, controls visible, no panel in the way.
        if panel != nil { withAnimation(reduceMotion ? nil : Motion.smooth) { panel = nil } }
        showOverlay(false)
    }

    // MARK: Corners and bar

    private var corners: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                topLeading
                Spacer(minLength: Space.xl)
                topTrailing
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: Space.xl) {
                bottomLeading
                Spacer(minLength: 0)
                if panel == nil { bottomTrailing }
            }
            // The side panel carries its own Live / Play controls; the bar would only be squeezed beside it.
            if panel == nil {
                controlBar
                    .padding(.top, Space.xl)
            }
        }
        .padding(TVSize.margin)
        .padding(.vertical, -Space.l)
    }

    @ViewBuilder
    private var topLeading: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if !connection.playback.isLive, let date = connection.playback.date {
                let rate = connection.playback.rate
                TVBadge(([connection.playback.isPlaying ? "Playback" : "Paused", date.tvStamp] + (rate == 1 ? [] : ["\(Int(rate))×"]))
                    .joined(separator: "  "), style: .accent)
                    .accessibilityLabel("Playing back from \(date.formatted(date: .abbreviated, time: .standard))")
            } else {
                let live = connection.phase == .connected
                TVLED(live ? Palette.live : Palette.textTertiary, label: live ? "Live" : "Off air", pulsing: live).id(live)
            }
            Text(camera.name).tv(.navTitle).lineLimit(1)
        }
        .shadow(color: Palette.frame.opacity(0.8), radius: Space.s)
    }

    @ViewBuilder
    private var topTrailing: some View {
        HStack(spacing: Space.m) {
            if let status = connection.status, connection.phase == .connected {
                if status.isRecording { TVBadge("Rec", style: .recording) }
                if status.nightActive { TVBadge("Night", style: .filled) }
                if status.effectiveQuality != status.quality { TVBadge("Hot", style: .outline) }
            }
            if let battery = connection.tvBattery {
                HStack(spacing: Space.s) {
                    Image(systemName: battery.symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(battery.tint)
                    Text(battery.text).tv(.readout, color: battery.tint)
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.s + Space.xxs)
                .background(Palette.frame.opacity(0.55), in: .continuous(Radius.chip))
                .accessibilityLabel("Camera battery \(battery.text)")
            }
        }
    }

    @ViewBuilder
    private var bottomLeading: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            let stream = connection.tvStreamReadout
            if !stream.isEmpty { TVReadoutLine(stream, color: Palette.textPrimary) }
            HStack(spacing: Space.m) {
                TVLED(linkColor)
                TVReadoutLine(connection.tvPathReadout)
            }
        }
        .shadow(color: Palette.frame.opacity(0.9), radius: Space.s)
        .accessibilityElement(children: .combine)
    }

    private var linkColor: Color {
        switch connection.phase {
        case .connected: connection.stats.path == .relay ? Palette.warn : Palette.ok
        case .connecting: Palette.warn
        case .failed, .rejected: Palette.live
        case .idle: Palette.textTertiary
        }
    }

    @ViewBuilder
    private var bottomTrailing: some View {
        let listening = connection.isListening && hub.audioFocus == connection.id
        HStack(spacing: Space.m) {
            Image(systemName: listening ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(listening ? Palette.textPrimary : Palette.textTertiary)
            TVLevelMeter(level: listening ? (connection.stats.audioLevel ?? 0) : 0)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .background(Palette.frame.opacity(0.55), in: .continuous(Radius.chip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera sound")
        .accessibilityValue(listening ? "\(Int((connection.stats.audioLevel ?? 0) * 100)) percent" : "Muted")
    }

    private var controlBar: some View {
        HStack(spacing: Space.l) {
            Button { connection.goLive() } label: {
                HStack(spacing: Space.s) {
                    Circle().fill(Palette.live).frame(width: Space.m, height: Space.m)
                    Text("Live")
                }
            }
            .buttonStyle(.tvPill(isOn: connection.playback.isLive))
            .focused(focus, equals: .bar(.live))
            .accessibilityLabel(connection.playback.isLive ? "Live" : "Back to live")

            Button { connection.play(from: (connection.playback.date ?? Date()).addingTimeInterval(-60)) } label: {
                Label("−60 s", systemImage: "gobackward.60")
            }
            .buttonStyle(.tvPill())
            .focused(focus, equals: .bar(.rewind))
            .disabled(connection.phase != .connected)
            .accessibilityLabel("Back 60 seconds")

            if !connection.playback.isLive {
                Button { cycleRate() } label: {
                    Text("Speed \(Int(connection.playback.rate))×")
                }
                .buttonStyle(.tvPill(isOn: connection.playback.rate != 1))
                .focused(focus, equals: .bar(.speed))
                .accessibilityLabel("Playback speed \(Int(connection.playback.rate)) times")
                .accessibilityHint("Cycles 1, 2, 4 and 8 times")
            }

            Button { openPanel(.timeline) } label: { Label("Timeline", systemImage: "timeline.selection") }
                .buttonStyle(.tvPill())
                .focused(focus, equals: .bar(.timeline))

            Button { openPanel(.events) } label: { Label("Events", systemImage: "bell.fill") }
                .buttonStyle(.tvPill())
                .focused(focus, equals: .bar(.events))

            Button {
                hub.audioFocus = hub.audioFocus == connection.id ? "" : connection.id
                if hub.audioFocus == connection.id { connection.isListening = true }
            } label: {
                Label("Listen", systemImage: "ear")
            }
            .buttonStyle(.tvPill(isOn: hub.audioFocus == connection.id && connection.isListening))
            .focused(focus, equals: .bar(.listen))
            .accessibilityValue(hub.audioFocus == connection.id ? "On" : "Off")

            Button { connection.isListening.toggle() } label: {
                Label("Mute", systemImage: connection.isListening ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.tvPill(isOn: !connection.isListening))
            .focused(focus, equals: .bar(.mute))
            .accessibilityValue(connection.isListening ? "Sound on" : "Muted")
        }
        .labelStyle(TVBarLabelStyle())
        .frame(maxWidth: .infinity)
        .focusSection()
        .onMoveCommand { direction in
            // Nothing above the bar is focusable: moving up puts the picture back in charge.
            if direction == .up { hideOverlay() }
        }
    }

    private func cycleRate() {
        let current = connection.playback.rate
        let index = Self.rates.firstIndex(of: current) ?? 0
        connection.setRate(Self.rates[(index + 1) % Self.rates.count])
    }

    private func openPanel(_ tab: TimelinePanelTV.Tab) {
        withAnimation(reduceMotion ? nil : Motion.smooth) {
            overlayVisible = true
            panel = tab
        }
        focus.wrappedValue = .panel
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch connection.phase {
        case .connected:
            if !connection.hasVideo { statusCard(symbol: nil, title: "Waiting for video", message: nil) }
        case let .connecting(message):
            statusCard(symbol: nil, title: message, message: nil)
        case let .failed(message):
            statusCard(symbol: "wifi.exclamationmark", title: "Can't reach \(camera.name)", message: message)
        case let .rejected(message):
            statusCard(symbol: "lock.fill", title: "Not allowed", message: message)
        case .idle:
            EmptyView()
        }
    }

    private func statusCard(symbol: String?, title: String, message: String?) -> some View {
        VStack(spacing: Space.l) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 48, weight: .semibold)).foregroundStyle(Palette.accent)
            } else {
                ProgressView().tint(Palette.textSecondary).scaleEffect(1.8).padding(.bottom, Space.m)
            }
            Text(title).tv(.title).multilineTextAlignment(.center)
            if let message { Text(message).tv(.callout, color: Palette.textSecondary).multilineTextAlignment(.center) }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: 820)
        .panel(fill: Palette.surface.opacity(0.9), padding: nil)
        .allowsHitTesting(false)
    }
}

/// Glyph then caps text, both at TV size, inside pill buttons.
struct TVBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.m) {
            configuration.icon.font(.system(size: 24, weight: .semibold))
            configuration.title
        }
    }
}
