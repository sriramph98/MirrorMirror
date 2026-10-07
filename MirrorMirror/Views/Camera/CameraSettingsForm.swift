import SwiftUI

/// Camera settings. Used on the camera itself and, through a binding that forwards changes
/// over the data channel, from a viewer.
struct CameraSettingsForm: View {
    @Binding var settings: CameraSettings
    var storageUsed: Int64?
    var storageFree: Int64?

    var body: some View {
        Form {
            Section("Camera") {
                TextField("Name", text: $settings.name)
                Picker("Stream quality", selection: $settings.quality) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text("\(preset.title) · \(preset.detail)").tag(preset)
                    }
                }
                Toggle("Lower quality when hot", isOn: $settings.adaptToHeat)
            }

            Section {
                Picker("Mode", selection: $settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Record audio", isOn: $settings.recordAudio)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Storage limit")
                        Spacer()
                        Text("\(Int(settings.storageCapGB)) GB").foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.storageCapGB, in: 1...100, step: 1)
                }
                if let storageUsed {
                    LabeledContent("Used", value: storageUsed.byteString)
                }
                if let storageFree {
                    LabeledContent("Free on device", value: storageFree.byteString)
                }
            } header: {
                Text("Recording")
            } footer: {
                Text(settings.recordingMode.detail)
            }

            Section {
                Toggle("Motion detection", isOn: $settings.motionEnabled)
                if settings.motionEnabled {
                    SensitivitySlider(value: $settings.motionSensitivity)
                    Toggle("Recognise people & pets", isOn: $settings.detectPeopleAndPets)
                }
                Toggle("Sound detection", isOn: $settings.soundEnabled)
                if settings.soundEnabled {
                    SensitivitySlider(value: $settings.soundSensitivity)
                    ForEach(EventKind.soundKinds, id: \.self) { kind in
                        Toggle(isOn: Binding(
                            get: { settings.soundKinds.contains(kind) },
                            set: { on in if on { settings.soundKinds.insert(kind) } else { settings.soundKinds.remove(kind) } }
                        )) {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                }
                Toggle("Notify viewers", isOn: $settings.notifyViewers)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Detection runs on the camera device. Nothing is uploaded. Viewers get a notification, at most one a minute.")
            }

            Section {
                Picker("Night vision", selection: $settings.nightMode) {
                    ForEach(NightMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Enhance low-light image", isOn: $settings.nightEnhance)
                Picker("Anti-flicker", selection: $settings.mainsFrequency) {
                    ForEach(MainsFrequency.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Night Vision")
            } footer: {
                Text("Anti-flicker matches the camera to your mains power so dim bulbs don't strobe. Auto uses your region.")
            }

            Section("Camera Device") {
                Picker("Dim screen after", selection: $settings.autoDimAfter) {
                    Text("Never").tag(TimeInterval(0))
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                }
                VStack(alignment: .leading) {
                    Text("Talk-back volume")
                    Slider(value: $settings.speakerVolume, in: 0...1)
                }
            }
        }
    }
}

private struct SensitivitySlider: View {
    @Binding var value: Double

    var body: some View {
        HStack {
            Text("Low").font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: 0...1)
            Text("High").font(.caption).foregroundStyle(.secondary)
        }
    }
}
