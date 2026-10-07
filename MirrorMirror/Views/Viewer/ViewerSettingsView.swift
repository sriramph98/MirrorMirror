import SwiftUI
import MirrorUI

/// Viewer settings. A sheet on iPhone (with a close button), the detail column on iPad.
struct ViewerSettingsView: View {
    @EnvironmentObject private var hub: ViewerHub
    /// Nil when embedded (iPad detail): no close button.
    var onClose: (() -> Void)? = nil

    @State private var turnURL = ConnectionPreferences.turnURL
    @State private var turnUsername = ConnectionPreferences.turnUsername
    @State private var turnCredential = ConnectionPreferences.turnCredential
    @State private var showGallery = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Settings", leadingAction: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    thisDevice
                    alerts
                    relay
                    about
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .canvasBackground()
        .onDisappear(perform: save)
        .onAppear { if ScreenHook.screen == "gallery" { showGallery = true } }
        .onChange(of: turnURL) { _, _ in save() }
        .onChange(of: turnUsername) { _, _ in save() }
        .onChange(of: turnCredential) { _, _ in save() }
        .fullScreenCover(isPresented: $showGallery) {
            DesignSystemGallery(onClose: { showGallery = false })
        }
    }

    private func save() {
        ConnectionPreferences.turnURL = turnURL
        ConnectionPreferences.turnUsername = turnUsername
        ConnectionPreferences.turnCredential = turnCredential
    }

    // MARK: Sections

    private var thisDevice: some View {
        SettingsSection("This device", symbol: "iphone", footer: cloudFooter) {
            ValueRow("Name", value: DeviceIdentity.name)
            ValueRow("Watch away from home", value: hub.cloudAvailable ? "On · iCloud" : "Off",
                     valueColor: hub.cloudAvailable ? Palette.ok : Palette.textSecondary)
        }
    }

    private var cloudFooter: String? {
        guard !hub.cloudAvailable else { return nil }
        return CloudRelay.shared.isConfigured
            ? "Sign in to iCloud in Settings to watch cameras from anywhere and get alerts. On the same Wi-Fi everything works without it."
            : "This build has no iCloud capability, so only cameras on the same network can be watched."
    }

    @ViewBuilder
    private var alerts: some View {
        SettingsSection("Alerts", symbol: "bell.fill", footer: "Motion, sound, low battery and overheating alerts from each camera.") {
            if hub.cameras.isEmpty {
                ValueRow("No cameras paired", value: "--", valueColor: Palette.textTertiary)
            }
            ForEach(hub.cameras) { camera in
                ToggleRow(camera.name, isOn: Binding(get: { camera.notificationsEnabled },
                                                     set: { hub.setNotifications(camera, enabled: $0) }))
            }
        }
    }

    private var relay: some View {
        SettingsSection("Relay server", symbol: "point.3.connected.trianglepath.dotted",
                        footer: "Optional. Most networks connect directly. If a camera never connects from a particular network (some carriers and offices block it), add a TURN relay you trust. Video through a relay is still end-to-end encrypted.") {
            RelayField(label: "URL", placeholder: "turn:turn.example.com:3478", text: $turnURL)
            RelayField(label: "User", placeholder: "username", text: $turnUsername)
            RelayField(label: "Secret", placeholder: "credential", text: $turnCredential, secure: true)
        }
    }

    private var about: some View {
        SettingsSection("About", symbol: "info.circle.fill") {
            ActionRow("Design system", symbol: "swatchpalette") { showGallery = true }
            ValueRow("Version", value: Self.version)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// A caps label and a monospaced field, for technical values like server addresses.
private struct RelayField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    @ScaledMetric(relativeTo: .caption) private var labelWidth = ControlSize.toolLarge + Space.l

    var body: some View {
        HStack(spacing: Space.m) {
            Text(label).type(.caps)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: labelWidth, alignment: .leading)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(.URL)
                }
            }
            .type(.readoutLarge)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: ControlSize.toolLarge)
    }
}
