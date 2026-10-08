import SwiftUI
import MirrorUI

/// Remote control of the camera from the viewer: an instrument cluster (battery, storage, heat)
/// over grouped settings panels.
struct CameraControlsSheet: View {
    @ObservedObject var connection: CameraConnection
    @Environment(\.dismiss) private var dismiss
    @State private var showAllSettings = false

    // Optimistic values: shown from the moment the user changes them until the camera's next
    // status report agrees (or a few seconds pass), so controls don't snap back mid-gesture.
    @State private var zoom = Pending<Double>()
    @State private var lens = Pending<Double>()
    @State private var night = Pending<NightMode>()
    @State private var torch = Pending<Bool>()
    @State private var quality = Pending<QualityPreset>()
    @State private var recording = Pending<Bool>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(connection.camera.name, leadingAction: { dismiss() })
                if let status = connection.status {
                    ScrollView {
                        content(status)
                            .padding(.horizontal, Space.l)
                            .padding(.bottom, Space.xl)
                            .readableWidth()
                    }
                    .scrollIndicators(.hidden)
                } else {
                    Spacer()
                    EmptyState(symbol: "video.slash", title: "Not connected", message: "Controls appear once the camera connects.")
                    Spacer()
                }
            }
            .canvasBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showAllSettings) {
                if let status = connection.status {
                    RemoteSettingsView(connection: connection, initial: status.settings)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func content(_ status: CameraStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            cluster(status)
            cameraSection(status)
            SettingsSection("Night", symbol: "moon.stars.fill",
                            footer: status.nightActive ? "Night vision is on now." : "Auto switches to night vision when the room gets dark.") {
                SettingRow("Night vision") {
                    SegmentPill(NightMode.allCases, selection: binding($night, status.nightMode) { connection.send(.setNightMode($0)) }) { $0.title }
                }
            }
            streamSection(status)
            recordingSection(status)
            SettingsSection {
                ActionRow("All camera settings", symbol: "gearshape") { showAllSettings = true }
            }
        }
        .onChange(of: connection.status) { _, status in
            guard let status else { return }
            zoom.settle(status.zoom)
            lens.settle(status.zoom, matches: { abs($0 - $1) < 0.05 })
            night.settle(status.nightMode)
            torch.settle(status.torchOn)
            quality.settle(status.quality)
            recording.settle(status.isRecording)
        }
    }

    // MARK: Instrument cluster

    private func cluster(_ status: CameraStatus) -> some View {
        let total = Double(status.storageUsedBytes + status.storageFreeBytes)
        let used = total > 0 ? Double(status.storageUsedBytes) / total : 0
        let thermal = ProcessInfo.ThermalState(rawValue: status.thermal)
        return VStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                InstrumentGauge(value: status.batteryLevel ?? 0,
                                label: status.isCharging ? "Charging" : "Battery",
                                valueText: status.batteryLevel.map { "\(Int($0 * 100))%" } ?? "–",
                                tint: Palette.ok)
                InstrumentGauge(value: used, label: "Storage", valueText: "\(Int((used * 100).rounded()))%", tint: Palette.info)
                InstrumentGauge(value: Double(min(3, max(0, status.thermal))) / 3, label: "Heat",
                                valueText: thermal?.label ?? "–",
                                tint: status.thermal >= 2 ? Palette.live : Palette.warn, ticks: 18)
            }
            ReadoutLine(["\(status.viewerCount) watching",
                         "\(status.storageUsedBytes.byteString) used",
                         "\(status.storageFreeBytes.byteString) free"],
                        color: Palette.textTertiary)
        }
        .panel(padding: Space.l)
    }

    // MARK: Sections

    private func cameraSection(_ status: CameraStatus) -> some View {
        SettingsSection("Camera", symbol: "camera") {
            if status.lenses.count > 1 {
                SettingRow("Lens") {
                    let nearest = status.lenses.min { abs($0.factor - status.zoom) < abs($1.factor - status.zoom) }?.factor ?? 1
                    SegmentPill(status.lenses.map(\.factor), selection: binding($lens, nearest) { connection.send(.setLens($0)) }) { factor in
                        status.lenses.first { $0.factor == factor }?.label ?? "\(factor)"
                    }
                }
            }
            if status.maxZoom > 1 {
                let lower = status.lenses.first?.factor ?? 1
                RulerRow("Zoom", value: binding($zoom, status.zoom) { connection.send(.setZoom($0)) },
                         in: lower...max(lower + 0.1, status.maxZoom), step: 0.1, labelEvery: 5) { String(format: "%.1f×", $0) }
            }
            SettingRow("Facing", detail: status.usingFrontCamera ? "Front camera" : "Back camera") {
                Button { connection.send(.flipCamera) } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                        Text(status.usingFrontCamera ? "Front" : "Back")
                    }
                }
                .buttonStyle(.pill())
                .accessibilityLabel("Switch camera")
                .accessibilityValue(status.usingFrontCamera ? "Front" : "Back")
            }
            if status.torchAvailable {
                let isOn = torch.value(or: status.torchOn)
                SettingRow("Light", detail: isOn ? "Torch on" : nil) {
                    Button {
                        torch.set(!isOn)
                        connection.send(.setTorch(!isOn))
                    } label: {
                        Image(systemName: isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                    .buttonStyle(.tool(isOn: isOn))
                    .accessibilityLabel("Light")
                    .accessibilityValue(isOn ? "On" : "Off")
                }
            }
        }
    }

    private func streamSection(_ status: CameraStatus) -> some View {
        let reduced = status.effectiveQuality != status.quality
        return SettingsSection("Stream", symbol: "dot.radiowaves.left.and.right",
                               footer: reduced ? "The camera is warm, so it's streaming at \(status.effectiveQuality.title) (\(status.effectiveQuality.detail)) until it cools down." : nil) {
            MenuRow("Quality", options: QualityPreset.allCases,
                    selection: binding($quality, status.quality) { connection.send(.setQuality($0)) }) { "\($0.title) · \($0.detail)" }
            if reduced {
                SettingRow("Heat", detail: "Reduced to \(status.effectiveQuality.title)") {
                    LED(Palette.warn, label: "Hot")
                }
            }
        }
    }

    private func recordingSection(_ status: CameraStatus) -> some View {
        let isRecording = recording.value(or: status.isRecording)
        return SettingsSection("Recording", symbol: "record.circle") {
            ToggleRow(isRecording ? "Recording" : "Not recording", detail: status.recordingMode.title,
                      isOn: Binding(get: { isRecording }, set: { on in
                          recording.set(on)
                          connection.send(.setRecording(on))
                      }))
            ValueRow("Storage used", value: status.storageUsedBytes.byteString)
            ValueRow("Free on camera", value: status.storageFreeBytes.byteString)
        }
    }

    /// Shows the pending value until the camera reports it; records and sends changes.
    private func binding<Value: Equatable>(_ pending: Binding<Pending<Value>>, _ reported: Value,
                                           send: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { pending.wrappedValue.value(or: reported) },
            set: { value in
                pending.wrappedValue.set(value)
                send(value)
            }
        )
    }
}

/// A locally-set value awaiting confirmation from the camera's status reports.
private struct Pending<Value: Equatable> {
    private var value: Value?
    private var since: Date?

    func value(or reported: Value) -> Value { value ?? reported }

    mutating func set(_ newValue: Value) {
        value = newValue
        since = Date()
    }

    /// Drop the local value once the camera agrees, or after a few seconds regardless.
    mutating func settle(_ reported: Value, matches: (Value, Value) -> Bool = { $0 == $1 }) {
        guard let value, let since else { return }
        if matches(value, reported) || Date().timeIntervalSince(since) > 4 {
            self.value = nil
            self.since = nil
        }
    }
}

/// Edits the camera's full settings remotely; changes are sent after a short pause in typing/sliding.
private struct RemoteSettingsView: View {
    @ObservedObject var connection: CameraConnection
    @State var settings: CameraSettings
    @State private var sendTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(connection: CameraConnection, initial: CameraSettings) {
        self.connection = connection
        _settings = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Camera settings", leadingSymbol: "chevron.left", leadingAction: { dismiss() })
            CameraSettingsForm(settings: $settings, storageUsed: connection.status?.storageUsedBytes, storageFree: connection.status?.storageFreeBytes)
                .readableWidth()
        }
        .canvasBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .onChange(of: settings) { _, new in
            sendTask?.cancel()
            sendTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                connection.send(.updateSettings(new))
            }
        }
    }
}
