import SwiftUI

/// Remote control of the camera from the viewer.
struct CameraControlsSheet: View {
    @ObservedObject var connection: CameraConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let status = connection.status {
                    form(status)
                } else {
                    ContentUnavailableView("Not connected", systemImage: "video.slash", description: Text("Controls appear once the camera connects."))
                }
            }
            .navigationTitle(connection.camera.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func form(_ status: CameraStatus) -> some View {
        Form {
            Section("Camera") {
                if status.lenses.count > 1 {
                    Picker("Lens", selection: Binding(
                        get: { status.lenses.min { abs($0.factor - status.zoom) < abs($1.factor - status.zoom) }?.factor ?? 1 },
                        set: { connection.send(.setLens($0)) }
                    )) {
                        ForEach(status.lenses) { Text($0.label).tag($0.factor) }
                    }
                    .pickerStyle(.segmented)
                }
                if status.maxZoom > 1 {
                    VStack(alignment: .leading) {
                        Text("Zoom \(String(format: "%.1f×", status.zoom))")
                        Slider(value: Binding(get: { status.zoom }, set: { connection.send(.setZoom($0)) }),
                               in: (status.lenses.first?.factor ?? 1)...status.maxZoom)
                    }
                }
                Button {
                    connection.send(.flipCamera)
                } label: {
                    Label(status.usingFrontCamera ? "Switch to back camera" : "Switch to front camera", systemImage: "camera.rotate")
                }
                if status.torchAvailable {
                    Toggle(isOn: Binding(get: { status.torchOn }, set: { connection.send(.setTorch($0)) })) {
                        Label("Light", systemImage: "flashlight.on.fill")
                    }
                }
            }

            Section("Night vision") {
                Picker("Night vision", selection: Binding(get: { status.nightMode }, set: { connection.send(.setNightMode($0)) })) {
                    ForEach(NightMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if status.nightActive {
                    Label("Night vision is on", systemImage: "moon.stars.fill").foregroundStyle(Theme.accent)
                }
            }

            Section {
                Picker("Quality", selection: Binding(get: { status.quality }, set: { connection.send(.setQuality($0)) })) {
                    ForEach(QualityPreset.allCases) { Text("\($0.title) · \($0.detail)").tag($0) }
                }
                if status.effectiveQuality != status.quality {
                    Label("Reduced to \(status.effectiveQuality.title) while the camera is hot", systemImage: "thermometer.high")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Stream")
            }

            Section("Recording") {
                Toggle(isOn: Binding(get: { status.isRecording }, set: { connection.send(.setRecording($0)) })) {
                    Label(status.isRecording ? "Recording" : "Not recording", systemImage: "record.circle")
                }
                LabeledContent("Mode", value: status.recordingMode.title)
                LabeledContent("Storage used", value: status.storageUsedBytes.byteString)
                LabeledContent("Free on camera", value: status.storageFreeBytes.byteString)
            }

            Section("Camera device") {
                LabeledContent("Battery", value: status.batteryLevel.map { "\(Int($0 * 100))%\(status.isCharging ? " · charging" : "")" } ?? "Unknown")
                LabeledContent("Temperature", value: ProcessInfo.ThermalState(rawValue: status.thermal)?.label ?? "Unknown")
                LabeledContent("Viewers", value: "\(status.viewerCount)")
            }

            Section {
                NavigationLink("All camera settings") {
                    RemoteSettingsView(connection: connection, initial: status.settings)
                }
            }
        }
    }
}

/// Edits the camera's full settings remotely; changes are sent after a short pause in typing/sliding.
private struct RemoteSettingsView: View {
    @ObservedObject var connection: CameraConnection
    @State var settings: CameraSettings
    @State private var sendTask: Task<Void, Never>?

    init(connection: CameraConnection, initial: CameraSettings) {
        self.connection = connection
        _settings = State(initialValue: initial)
    }

    var body: some View {
        CameraSettingsForm(settings: $settings, storageUsed: connection.status?.storageUsedBytes, storageFree: connection.status?.storageFreeBytes)
            .navigationTitle("Camera Settings")
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
