import SwiftUI

/// Full-screen "this device is the camera" screen.
struct CameraModeView: View {
    @StateObject private var host = CameraHost()
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var isDimmed = false
    @State private var lastInteraction = Date()
    @State private var savedBrightness: CGFloat?
    @State private var eventToast: CameraEvent?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(sink: host.preview).ignoresSafeArea()

            if !isDimmed {
                controls
                    .transition(.opacity)
            }

            if let event = eventToast, !isDimmed {
                VStack {
                    Spacer()
                    ToastView(text: "\(event.label) · \(event.date.formatted(date: .omitted, time: .shortened))")
                        .padding(.bottom, 170)
                }
            }

            if isDimmed {
                DimmedOverlay(host: host)
                    .onTapGesture { wake() }
            }
        }
        .statusBarHidden(isDimmed)
        .persistentSystemOverlays(isDimmed ? .hidden : .automatic)
        .simultaneousGesture(TapGesture().onEnded { lastInteraction = Date() })
        .task { await host.start() }
        .task { await dimLoop() }
        .onDisappear {
            restoreBrightness()
            host.stop()
        }
        .onChange(of: host.recentEvents.first) { _, event in
            guard let event else { return }
            withAnimation { eventToast = event }
            Task {
                try? await Task.sleep(for: .seconds(4))
                if eventToast == event { withAnimation { eventToast = nil } }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet(host: host).onAppear { lastInteraction = Date() }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                CameraSettingsForm(settings: $host.settings, storageUsed: host.store.totalBytes)
                    .navigationTitle("Camera Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
        }
        .confirmationDialog("Stop the camera?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Camera", role: .destructive) { dismiss() }
        } message: {
            Text("Viewers will be disconnected and recording stops until you start camera mode again.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                OverlayButton(systemName: "xmark", size: 40) { confirmStop = true }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    StatusPill(text: viewersText, color: host.viewers.isEmpty ? .orange : .green)
                    HStack(spacing: 8) {
                        if host.isRecording { StatusPill(text: "REC", color: .red) }
                        if host.engineState.nightActive { StatusPill(text: "Night", color: Theme.accent, systemImage: "moon.stars.fill") }
                        StatusPill(text: host.batteryLevel.map { "\(Int($0 * 100))%" } ?? "–",
                                   color: host.isCharging ? .green : .white,
                                   systemImage: batterySymbol(host.batteryLevel, charging: host.isCharging))
                    }
                    if host.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                        StatusPill(text: "\(host.thermal.label) · quality lowered", color: .orange, systemImage: "thermometer.high")
                    }
                    if host.engineState.isSynthetic {
                        StatusPill(text: "Test pattern (no camera)", color: .yellow, systemImage: "exclamationmark.triangle.fill")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if let talker = host.talkingViewer {
                StatusPill(text: "\(talker) is talking", color: Theme.accent, systemImage: "waveform")
                    .padding(.top, 12)
            }

            Spacer()

            ActivityMeters(motion: host.motionLevel, sound: host.soundLevel)
                .padding(.bottom, 12)

            if host.engineState.lenses.count > 1 {
                LensPicker(lenses: host.engineState.lenses, zoom: host.engineState.zoom) { host.setLens($0) }
                    .padding(.bottom, 16)
            }

            HStack {
                OverlayButton(systemName: "qrcode") { showPairing = true }
                Spacer()
                OverlayButton(systemName: "camera.rotate") { host.flipCamera() }
                Spacer()
                RecordButton(isRecording: host.isRecording) { host.setRecording(!host.isRecording) }
                Spacer()
                OverlayButton(systemName: host.engineState.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                              isOn: host.engineState.torchOn) { host.setTorch(!host.engineState.torchOn) }
                    .disabled(!host.engineState.torchAvailable)
                    .opacity(host.engineState.torchAvailable ? 1 : 0.4)
                Spacer()
                OverlayButton(systemName: "gearshape") { showSettings = true }
            }
            .padding(.horizontal, 24)

            Button {
                dim()
            } label: {
                Label("Dim screen to save battery", systemImage: "moon.zzz.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }

    private var viewersText: String {
        switch host.viewers.count {
        case 0: "Waiting for viewers"
        case 1: "\(host.viewers[0].name) watching"
        default: "\(host.viewers.count) watching"
        }
    }

    // MARK: Dimming

    private func dimLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let after = host.settings.autoDimAfter
            if after > 0, !isDimmed, !showPairing, !showSettings, Date().timeIntervalSince(lastInteraction) > after {
                dim()
            }
        }
    }

    private func dim() {
        withAnimation { isDimmed = true }
        host.setPreviewVisible(false)
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
    }

    private func wake() {
        restoreBrightness()
        host.setPreviewVisible(true)
        lastInteraction = Date()
        withAnimation { isDimmed = false }
    }

    private func restoreBrightness() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }
}

private struct DimmedOverlay: View {
    @ObservedObject var host: CameraHost

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 44, weight: .thin, design: .rounded))
                }
                HStack(spacing: 8) {
                    Circle().fill(host.isRecording ? .red : .gray).frame(width: 6, height: 6)
                    Text(host.viewers.isEmpty ? "Camera on · waiting for viewers" : "\(host.viewers.count) watching")
                }
                .font(.footnote)
                Text("Tap to wake").font(.caption2).padding(.top, 24)
            }
            .foregroundStyle(.white.opacity(0.35))
        }
        .contentShape(Rectangle())
    }
}

struct LensPicker: View {
    let lenses: [LensOption]
    let zoom: Double
    let onSelect: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(lenses) { lens in
                let selected = abs(zoom - lens.factor) < 0.05
                Button { onSelect(lens.factor) } label: {
                    Text(selected && zoom != lens.factor ? String(format: "%.1f×", zoom) : lens.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(selected ? Theme.accent : .white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(width: isRecording ? 28 : 58, height: isRecording ? 28 : 58)
                    .animation(.spring(duration: 0.3), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct ActivityMeters: View {
    let motion: Double
    let sound: Double

    var body: some View {
        HStack(spacing: 16) {
            meter("figure.walk.motion", motion)
            meter("waveform", sound)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func meter(_ symbol: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption)
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(value > 0.5 ? Theme.accent : .white).frame(width: geo.size.width * min(1, max(0.02, value)))
                    }
            }
            .frame(width: 60, height: 5)
        }
        .animation(.easeOut(duration: 0.3), value: value)
    }
}
