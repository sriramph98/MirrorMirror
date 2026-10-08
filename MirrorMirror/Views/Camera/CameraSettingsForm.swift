import SwiftUI
import MirrorUI

/// Camera settings. Used on the camera itself and, through a binding that forwards changes
/// over the data channel, from a viewer. Grouped panels on the canvas.
struct CameraSettingsForm: View {
    @Binding var settings: CameraSettings
    var storageUsed: Int64?
    var storageFree: Int64?
    /// False for a Mac's own camera: its window can't dim, so the row explains ⌘H instead.
    var dimsScreen = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                cameraSection
                recordingSection
                alertsSection
                nightSection
                deviceSection
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .canvasBackground()
    }

    // MARK: Sections

    private var cameraSection: some View {
        SettingsSection("Camera", symbol: "camera",
                        footer: "Streaming at \(settings.quality.detail). Viewers on slow connections get less.") {
            SettingRow("Name") {
                TextField("Camera name", text: $settings.name)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .type(.readoutLarge, color: Palette.textPrimary)
                    .textCase(nil)
            }
            MenuRow("Stream quality", options: QualityPreset.allCases, selection: $settings.quality) { $0.title }
            ToggleRow("Lower quality when hot", isOn: $settings.adaptToHeat)
        }
    }

    private var recordingSection: some View {
        SettingsSection("Recording", symbol: "record.circle", footer: settings.recordingMode.detail) {
            MenuRow("Mode", options: RecordingMode.allCases, selection: $settings.recordingMode) { $0.title }
            ToggleRow("Record audio", isOn: $settings.recordAudio)
            // The ruler starts at 0 so its labels land on round numbers; the cap never goes below 1 GB.
            RulerRow("Storage limit",
                     value: Binding(get: { settings.storageCapGB }, set: { settings.storageCapGB = max(1, $0) }),
                     in: 0...100, step: 1, labelEvery: 10) { "\(Int($0)) GB" }
            if let storageUsed {
                ValueRow("Used", value: storageUsed.byteString)
            }
            if let storageFree {
                ValueRow("Free on device", value: storageFree.byteString)
            }
        }
    }

    private var alertsSection: some View {
        SettingsSection("Alerts", symbol: "bell",
                        footer: "Detection runs on the camera device. Nothing is uploaded. Viewers get a notification, at most one a minute.") {
            ToggleRow("Motion detection", symbol: "figure.walk.motion", isOn: $settings.motionEnabled)
            if settings.motionEnabled {
                RulerRow("Motion sensitivity", value: percent($settings.motionSensitivity), in: 0...100, step: 1, labelEvery: 10) {
                    "\(Int($0))%"
                }
                ToggleRow("Recognise people & pets", symbol: "person.and.background.dotted", isOn: $settings.detectPeopleAndPets)
            }
            ToggleRow("Sound detection", symbol: "waveform", isOn: $settings.soundEnabled)
            if settings.soundEnabled {
                RulerRow("Sound sensitivity", value: percent($settings.soundSensitivity), in: 0...100, step: 1, labelEvery: 10) {
                    "\(Int($0))%"
                }
                ForEach(EventKind.soundKinds, id: \.self) { kind in
                    ToggleRow(kind.title, symbol: kind.symbol, isOn: soundKind(kind))
                }
            }
            ToggleRow("Notify viewers", symbol: "bell.badge", isOn: $settings.notifyViewers)
        }
    }

    private var nightSection: some View {
        SettingsSection("Night vision", symbol: "moon.stars",
                        footer: "Anti-flicker matches the camera to your mains power so dim bulbs don't strobe. Auto uses your region.") {
            SettingRow("Mode") {
                SegmentPill(NightMode.allCases, selection: $settings.nightMode) { $0.title }
                    .accessibilityLabel("Night vision")
            }
            ToggleRow("Enhance low-light image", isOn: $settings.nightEnhance)
            MenuRow("Anti-flicker", options: MainsFrequency.allCases, selection: $settings.mainsFrequency) { $0.title }
        }
    }

    private var deviceSection: some View {
        SettingsSection("Camera device", symbol: dimsScreen ? "iphone" : Platform.deviceSymbol,
                        footer: dimsScreen ? nil : "Press ⌘H to hide Mira while the camera keeps streaming and recording.") {
            if dimsScreen {
                MenuRow("Dim screen after", options: Self.dimOptions, selection: $settings.autoDimAfter) { Self.dimLabel($0) }
            } else {
                ValueRow("Hide window", value: "⌘H", symbol: "eye.slash")
            }
            RulerRow("Talk-back volume", value: percent($settings.speakerVolume), in: 0...100, step: 5, labelEvery: 4) {
                "\(Int($0))%"
            }
        }
    }

    // MARK: Helpers

    private static let dimOptions: [TimeInterval] = [0, 15, 30, 60, 300]

    private static func dimLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 0: "Never"
        case ..<60: "\(Int(seconds)) s"
        default: "\(Int(seconds / 60)) min"
        }
    }

    /// Shows a 0–1 value as 0–100 % on a ruler.
    private func percent(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { (value.wrappedValue * 100).rounded() }, set: { value.wrappedValue = $0 / 100 })
    }

    private func soundKind(_ kind: EventKind) -> Binding<Bool> {
        Binding(
            get: { settings.soundKinds.contains(kind) },
            set: { on in
                if on { settings.soundKinds.insert(kind) } else { settings.soundKinds.remove(kind) }
            }
        )
    }
}
