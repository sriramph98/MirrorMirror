import SwiftUI
import MirrorUI

/// Full-screen "this device is the camera" screen, laid out like a camera body (Kino):
/// readouts on top, the viewfinder in the middle, a row of tools and a deck with the record
/// button below. Landscape and iPad move the tools and deck into a rail on the right.
struct CameraModeView: View {
    @StateObject private var host = CameraHost()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var isDimmed = false
    @State private var lastInteraction = Date()
    @State private var savedBrightness: CGFloat?
    @State private var eventToast: CameraEvent?
    @State private var bracketFlash = false
    @State private var latestThumbnail: UIImage?

    var body: some View {
        GeometryReader { geo in
            // Side rail only when the screen is wider than tall; an upright iPad uses the bottom deck like an iPhone.
            let wide = geo.size.width > geo.size.height
            ZStack {
                Palette.frame.ignoresSafeArea()
                Group {
                    if wide { wideLayout } else { portraitLayout }
                }
                .accessibilityHidden(isDimmed)

                if isDimmed {
                    DimmedOverlay(host: host)
                        .onTapGesture { wake() }
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(isDimmed)
        .persistentSystemOverlays(isDimmed ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .simultaneousGesture(TapGesture().onEnded { lastInteraction = Date() })
        .task { await host.start() }
        .task { await dimLoop() }
        .task(id: host.latestEvent?.id) {
            latestThumbnail = host.latestEvent.flatMap { host.thumbnailImage(for: $0) }
        }
        // Time spent in a sheet counts as interaction, so closing one doesn't dim straight away.
        .onChange(of: showPairing) { lastInteraction = Date() }
        .onChange(of: showSettings) { lastInteraction = Date() }
        .onDisappear {
            restoreBrightness()
            host.stop()
        }
        .onChange(of: host.recentEvents.first) { _, event in
            guard let event else { return }
            withAnimation(Motion.smooth) { eventToast = event }
            flashBrackets()
            Task {
                try? await Task.sleep(for: .seconds(4))
                if eventToast == event { withAnimation(Motion.fade) { eventToast = nil } }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(host: host)
                .onAppear { lastInteraction = Date() }
                .presentationBackground(Palette.canvas)
                .presentationCornerRadius(Radius.deck)
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                SheetHeader("Camera settings", leadingAction: { showSettings = false })
                CameraSettingsForm(settings: $host.settings, storageUsed: host.store.totalBytes, storageFree: host.storageFreeBytes,
                                   dimsScreen: !Platform.isMac)
            }
            .canvasBackground()
            .presentationBackground(Palette.canvas)
            .presentationCornerRadius(Radius.deck)
        }
        .confirmationDialog("Stop the camera?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Camera", role: .destructive) { dismiss() }
        } message: {
            Text("Viewers will be disconnected and recording stops until you start camera mode again.")
        }
    }

    // MARK: - Layouts

    /// iPhone portrait: strips, viewfinder, tool row, deck.
    private var portraitLayout: some View {
        VStack(spacing: Space.m) {
            header.padding(.horizontal, Space.l)
            viewfinderArea(landscape: false)
                .padding(.horizontal, Space.m)
            HStack(spacing: 0) {
                Group { toolButtons }.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Space.m)
            deck
        }
        .padding(.top, Space.s)
    }

    /// Landscape and iPad: viewfinder on the left, tools column and deck rail on the right.
    private var wideLayout: some View {
        HStack(spacing: Space.l) {
            VStack(spacing: Space.m) {
                header
                viewfinderArea(landscape: true)
            }
            .padding(.leading, Space.l)
            .padding(.vertical, Space.m)

            VStack(spacing: Space.m) {
                toolButtons
            }
            .padding(.vertical, Space.m)

            rail
        }
    }

    // MARK: - Header

    /// Top strip and badge row. Fits on one line where there is room (landscape, iPad),
    /// otherwise splits into the strip and a badge row underneath.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.l) {
                closeButton
                micMeter
                viewerLED
                badges
                Spacer(minLength: Space.s)
                formatLine
                storageReadouts
            }
            VStack(spacing: Space.s) {
                HStack(spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        closeButton
                        micMeter
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    viewerLED.fixedSize()
                    storageReadouts
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(spacing: Space.s) {
                    badges
                    Spacer(minLength: Space.s)
                    formatLine
                }
            }
            // Very large Dynamic Type: one item per line.
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    closeButton
                    Spacer(minLength: Space.s)
                    storageReadouts
                }
                micMeter
                viewerLED
                badges
                formatLine
            }
        }
    }

    private var closeButton: some View {
        Button { confirmStop = true } label: { Image(systemName: "xmark") }
            .buttonStyle(.tool())
            .toolHover()
            .accessibilityLabel("Stop camera")
    }

    private var micMeter: some View {
        HStack(spacing: Space.s) {
            LevelMeter(level: host.engineState.hasAudio ? host.soundLevel : 0, segments: 10)
            Text("MIC").type(.caps, color: host.engineState.hasAudio ? Palette.textSecondary : Palette.textTertiary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(host.engineState.hasAudio ? "\(Int(host.soundLevel * 100)) percent" : "No microphone")
    }

    private var viewerLED: some View {
        let count = host.viewers.count
        return LED(count > 0 ? Palette.live : Palette.textTertiary,
                   label: count > 0 ? "\(count) WATCHING" : "WAITING",
                   pulsing: count > 0)
            .id(count > 0) // restart the pulse when someone starts watching
            .fixedSize()
            .accessibilityLabel(count > 0 ? "\(count) watching" : "Waiting for viewers")
    }

    private var storageReadouts: some View {
        HStack(spacing: Space.l) {
            if let level = host.batteryLevel {
                Readout("\(Int(level * 100))%", caption: host.isCharging ? "CHRG" : "BATT", alignment: .trailing,
                        color: level < 0.2 && !host.isCharging ? Palette.live : Palette.textPrimary)
            }
            Readout(hoursLeftText, caption: "LEFT", alignment: .trailing)
                .accessibilityLabel("About \(hoursLeftText.lowercased()) of recording left")
        }
        .fixedSize()
    }

    private var hoursLeftText: String {
        let hours = host.estimatedRecordingHoursLeft
        if hours >= 1 { return "\(Int(hours)) H" }
        return "\(Int(hours * 60)) MIN"
    }

    private var badges: some View {
        HStack(spacing: Space.xs) {
            if host.isRecording { Badge("REC", style: .recording) }
            if host.engineState.nightActive { Badge("NIGHT", style: .accent) }
            Badge(host.settings.nightMode.title, style: .outline)
                .accessibilityLabel("Night vision \(host.settings.nightMode.title)")
        }
        .fixedSize()
    }

    private var formatLine: some View {
        ReadoutLine(host.streamFormatItems)
            .fixedSize()
            .accessibilityLabel("Streaming \(host.streamFormatItems.joined(separator: ", "))")
    }

    // MARK: - Viewfinder

    /// Fills the available space when the picture's shape is close to it (a small crop, like Kino);
    /// otherwise the frame hugs the picture so nothing being recorded is hidden.
    private func viewfinderArea(landscape: Bool) -> some View {
        GeometryReader { geo in
            let picture = pictureAspect(landscape: landscape)
            let space = geo.size.width / max(geo.size.height, 1)
            // A Mac window is any shape the user drags it to; the picture always fits inside it.
            let fill = !Platform.isMac && max(picture, space) / min(picture, space) < Self.maxFillCrop
            viewfinder(fill: fill)
                .aspectRatio(fill ? nil : picture, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// CCTV-style 24-hour timecode in the viewfinder corner.
    private static let timecode: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// How far the picture may be cropped to fill the viewfinder (ratio of aspect ratios).
    private static let maxFillCrop: CGFloat = 1.3

    /// Frames are upright: portrait on a portrait device, landscape otherwise. The simulator's
    /// test pattern and a Mac's camera are always landscape.
    private func pictureAspect(landscape: Bool) -> CGFloat {
        let dims = host.effectiveQuality.dimensions
        let ratio = CGFloat(dims.long) / CGFloat(dims.short)
        return host.engineState.isSynthetic || landscape || Platform.isMac ? ratio : 1 / ratio
    }

    private func viewfinder(fill: Bool) -> some View {
        Viewfinder {
            ZStack {
                VideoSurface(sink: host.preview, fill: fill)
                if bracketFlash {
                    Color.clear
                        .focusBrackets(Palette.accent, length: Space.xxl, inset: 0)
                        .padding(Space.xxxl)
                        .transition(reduceMotion ? .opacity : .scale(scale: 1.12).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
        } topLeading: {
            VStack(alignment: .leading, spacing: Space.xs) {
                if host.engineState.isSynthetic {
                    Badge("TEST PATTERN", style: .filled)
                        .accessibilityLabel("No camera found, showing a test pattern")
                }
                if host.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    StatChip("QUALITY LOWERED", symbol: "thermometer.high", tint: Palette.warn)
                        .accessibilityLabel("\(host.thermal.label). Quality lowered to cool down")
                }
            }
        } topTrailing: {
            if let talker = host.talkingViewer {
                StatChip(talker, tag: "TALK", symbol: "waveform", tint: Palette.accent)
                    .accessibilityLabel("\(talker) is talking")
                    .transition(.opacity)
            }
        } bottomLeading: {
            HStack(spacing: Space.s) {
                LevelMeter(level: host.motionLevel, segments: 8)
                Text("MOTION").type(.caps)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(Palette.frame.opacity(0.45), in: .continuous(Radius.badge))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Motion level")
            .accessibilityValue("\(Int(host.motionLevel * 100)) percent")
        } bottomTrailing: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Badge(Self.timecode.string(from: context.date), style: .outline)
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            if let event = eventToast {
                Toast("\(event.label) · \(event.date.formatted(date: .omitted, time: .shortened))", symbol: event.kind.symbol)
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, Space.xxxl + Space.s)
            }
        }
        .animation(Motion.smooth, value: host.talkingViewer)
    }

    private func flashBrackets() {
        withAnimation(reduceMotion ? nil : Motion.snappy) { bracketFlash = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(reduceMotion ? nil : Motion.fade) { bracketFlash = false }
        }
    }

    // MARK: - Tools and deck

    @ViewBuilder
    private var toolButtons: some View {
        Button { showPairing = true } label: { Image(systemName: "qrcode") }
            .buttonStyle(.tool())
            .toolHover()
            .accessibilityLabel("Pair a viewer")
            .help("Pair a viewer")

        // A Mac has no front and back; the button only appears when there is another camera to switch to.
        if !Platform.isMac || host.engineState.cameraCount > 1 {
            Button { host.flipCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
                .buttonStyle(.tool())
                .toolHover()
                .accessibilityLabel("Switch camera")
                .help("Switch camera")
        }

        // Macs have no torch, so the control isn't shown there at all.
        if !Platform.isMac {
            let torch = host.engineState
            Button { host.setTorch(!torch.torchOn) } label: {
                Image(systemName: torch.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
            }
            .buttonStyle(.tool(isOn: torch.torchOn, tint: torch.torchAvailable ? Palette.textPrimary : Palette.textDisabled))
            .disabled(!torch.torchAvailable)
            .accessibilityLabel("Torch")
            .accessibilityValue(torch.torchAvailable ? (torch.torchOn ? "On" : "Off") : "Unavailable")
        }

        Button { cycleNightMode() } label: { Image(systemName: nightSymbol) }
            .buttonStyle(.tool(isOn: host.engineState.nightActive))
            .toolHover()
            .accessibilityLabel("Night vision")
            .accessibilityValue(host.settings.nightMode.title + (host.engineState.nightActive ? ", active" : ""))
            .accessibilityHint("Cycles Auto, On and Off")
            .help("Night vision: \(host.settings.nightMode.title)")

        Button { showSettings = true } label: { Image(systemName: "gearshape") }
            .buttonStyle(.tool())
            .toolHover()
            .accessibilityLabel("Camera settings")
            .help("Camera settings")
    }

    private var nightSymbol: String {
        switch host.settings.nightMode {
        case .auto: "moon.stars"
        case .on: "moon.stars.fill"
        case .off: "moon"
        }
    }

    private func cycleNightMode() {
        host.settings.nightMode = switch host.settings.nightMode {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }

    private var lensSelection: Binding<LensOption> {
        Binding(
            get: {
                let zoom = host.engineState.zoom
                return host.engineState.lenses.min { abs($0.factor - zoom) < abs($1.factor - zoom) } ?? LensOption(factor: 1)
            },
            set: { host.setLens($0.factor) }
        )
    }

    @ViewBuilder
    private var lensPill: some View {
        if host.engineState.lenses.count > 1 {
            SegmentPill(host.engineState.lenses, selection: lensSelection) { $0.label }
                .accessibilityLabel("Lens")
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: host.isRecording) { host.setRecording(!host.isRecording) }
    }

    /// iPhone and iPad dim the screen; a Mac can't, so the same slot hides the app (⌘H) instead.
    @ViewBuilder
    private var dimButton: some View {
        if Platform.isMac {
            VStack(spacing: Space.xs) {
                Button { MacApp.hide() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.tool(size: ControlSize.toolLarge))
                    .toolHover()
                    .accessibilityLabel("Hide MirrorMirror")
                    .accessibilityHint("Hides the window, like Command-H. The camera keeps running.")
                    .help("Hide MirrorMirror (⌘H). The camera keeps running.")
                Text("⌘H hides")
                    .type(.caps, color: Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        } else {
            Button { dim() } label: { Image(systemName: "moon.zzz") }
                .buttonStyle(.tool(size: ControlSize.toolLarge))
                .accessibilityLabel("Dim screen")
                .accessibilityHint("Turns the screen dark to save battery. The camera keeps running.")
        }
    }

    private var thumbnail: some View {
        EventThumbnail(event: host.latestEvent, image: latestThumbnail)
    }

    /// Portrait deck: lens pill, then thumbnail · record · dim.
    private var deck: some View {
        VStack(spacing: Space.l) {
            lensPill
            HStack {
                thumbnail.frame(maxWidth: .infinity, alignment: .leading)
                recordButton
                dimButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .padding(.bottom, Space.s)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Radius.deck, topTrailingRadius: Radius.deck, style: .continuous)
                .fill(Palette.surface)
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: Radius.deck, topTrailingRadius: Radius.deck, style: .continuous)
                        .strokeBorder(Palette.bevel, lineWidth: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Landscape / iPad deck: a vertical rail on the right edge.
    private var rail: some View {
        VStack(spacing: Space.xl) {
            Spacer(minLength: 0)
            thumbnail
            lensPill
            recordButton
            dimButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.l)
        .frame(minWidth: ControlSize.shutter + Space.xl * 2)
        .frame(maxHeight: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Radius.deck, bottomLeadingRadius: Radius.deck, style: .continuous)
                .fill(Palette.surface)
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: Radius.deck, bottomLeadingRadius: Radius.deck, style: .continuous)
                        .strokeBorder(Palette.bevel, lineWidth: 1)
                }
                .ignoresSafeArea(edges: [.trailing, .vertical])
        }
    }

    // MARK: - Dimming

    private func dimLoop() async {
        // A Mac window never dims itself; ⌘H hides the app instead.
        guard !Platform.isMac else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let after = host.settings.autoDimAfter
            if after > 0, !isDimmed, !showPairing, !showSettings, Date().timeIntervalSince(lastInteraction) > after {
                dim()
            }
        }
    }

    private func dim() {
        withAnimation(Motion.fade) { isDimmed = true }
        host.setPreviewVisible(false)
        // `UIScreen.brightness` is a no-op on the Mac; leave it alone so nothing is "restored" later.
        guard !Platform.isMac else { return }
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
    }

    private func wake() {
        restoreBrightness()
        host.setPreviewVisible(true)
        lastInteraction = Date()
        withAnimation(Motion.fade) { isDimmed = false }
    }

    private func restoreBrightness() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }
}

// MARK: - Latest event thumbnail

private struct EventThumbnail: View {
    let event: CameraEvent?
    let image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.raised
                Image(systemName: event?.kind.symbol ?? "bell.slash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(event == nil ? Palette.textTertiary : Palette.textSecondary)
            }
        }
        .frame(width: ControlSize.thumbnail, height: ControlSize.thumbnail)
        .clipShape(.continuous(Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.map { "Latest event: \($0.label), \($0.date.formatted(date: .omitted, time: .shortened))" } ?? "No events yet")
    }
}

// MARK: - Dimmed state

/// Black screen with a large clock and status lights. Drifts slowly so nothing burns in.
private struct DimmedOverlay: View {
    @ObservedObject var host: CameraHost

    var body: some View {
        ZStack {
            Palette.frame.ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: Space.l) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .type(.numeral, color: Palette.textSecondary)
                    VStack(alignment: .leading, spacing: Space.s) {
                        LED(host.isRecording ? Palette.live : Palette.textTertiary,
                            label: host.isRecording ? "RECORDING" : "NOT RECORDING")
                        LED(host.viewers.isEmpty ? Palette.textTertiary : Palette.live,
                            label: host.viewers.isEmpty ? "WAITING FOR VIEWERS" : "\(host.viewers.count) WATCHING")
                        if host.engineState.nightActive {
                            LED(Palette.night, label: "NIGHT VISION")
                        }
                    }
                    Text("TAP TO WAKE")
                        .type(.caps, color: Palette.textTertiary)
                        .padding(.top, Space.xl)
                }
                .offset(drift(context.date))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Wakes the screen")
    }

    /// A slow orbit, one step per half-minute, so the clock never sits on the same pixels.
    private func drift(_ date: Date) -> CGSize {
        let step = Double(Int(date.timeIntervalSince1970 / 30) % 12) / 12 * 2 * .pi
        return CGSize(width: Space.xl * cos(step), height: Space.xl * sin(step))
    }
}
