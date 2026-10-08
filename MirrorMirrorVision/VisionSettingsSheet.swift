import SwiftUI
import MirrorUI

/// Viewer settings on a glass sheet: cameras (rename, alerts, remove), pairing, relay server,
/// about, and the design system gallery.
struct VisionSettingsSheet: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss

    @State private var turnURL = ConnectionPreferences.turnURL
    @State private var turnUsername = ConnectionPreferences.turnUsername
    @State private var turnCredential = ConnectionPreferences.turnCredential
    @State private var showPairing = false
    @State private var showGallery = false
    @State private var renaming: PairedCamera?
    @State private var newName = ""
    @State private var removing: PairedCamera?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Settings", leadingAction: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    cameras
                    thisDevice
                    relay
                    about
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 640, minHeight: 680)
        .onDisappear(perform: save)
        .onChange(of: turnURL) { _, _ in save() }
        .onChange(of: turnUsername) { _, _ in save() }
        .onChange(of: turnCredential) { _, _ in save() }
        .sheet(isPresented: $showPairing) { PairingSheet().environmentObject(hub) }
        .sheet(isPresented: $showGallery) {
            DesignSystemGallery(onClose: { showGallery = false })
                .frame(minWidth: 900, minHeight: 700)
        }
        .alert("Rename camera", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let camera = renaming {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { hub.rename(camera, to: trimmed) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The name shows on this device only until the camera sends its own.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "camera")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let camera = removing { hub.remove(camera) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("You'll need to pair again to watch it from this device.")
        }
    }

    private func save() {
        ConnectionPreferences.turnURL = turnURL
        ConnectionPreferences.turnUsername = turnUsername
        ConnectionPreferences.turnCredential = turnCredential
    }

    // MARK: Sections

    private var cameras: some View {
        SettingsSection("Cameras", symbol: "video.fill", footer: "Alerts are motion, sound, low battery and overheating from that camera.") {
            if hub.cameras.isEmpty {
                ValueRow("No cameras paired", value: "--", valueColor: Palette.textTertiary)
            }
            ForEach(hub.cameras) { camera in
                cameraRow(camera)
            }
            ActionRow("Pair another device", symbol: "plus.viewfinder") { showPairing = true }
                .cardHover(Radius.control)
        }
    }

    private func cameraRow(_ camera: PairedCamera) -> some View {
        SettingRow(camera.name, detail: camera.source == .iCloud ? "From iCloud" : "Paired by invite") {
            HStack(spacing: Space.m) {
                LED(reachabilityColor(camera), label: reachabilityLabel(camera))
                Menu {
                    Button { newName = camera.name; renaming = camera } label: { Label("Rename", systemImage: "pencil") }
                    Button {
                        hub.setNotifications(camera, enabled: !camera.notificationsEnabled)
                    } label: {
                        Label(camera.notificationsEnabled ? "Mute alerts" : "Unmute alerts",
                              systemImage: camera.notificationsEnabled ? "bell.slash" : "bell")
                    }
                    Divider()
                    Button(role: .destructive) { removing = camera } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: camera.notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(camera.notificationsEnabled ? Palette.textPrimary : Palette.textTertiary)
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: VisionSize.toolSmall + Space.m, height: VisionSize.toolSmall)
                    .background(Palette.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .pillHover()
                .accessibilityLabel("Options for \(camera.name)")
                .accessibilityValue(camera.notificationsEnabled ? "Alerts on" : "Alerts muted")
            }
        }
    }

    private func reachabilityColor(_ camera: PairedCamera) -> Color {
        if hub.connection(for: camera).phase == .connected { return Palette.live }
        switch hub.reachability(of: camera) {
        case .localNetwork, .online: return Palette.ok
        case .offline, .unknown: return Palette.textTertiary
        }
    }

    private func reachabilityLabel(_ camera: PairedCamera) -> String {
        if hub.connection(for: camera).phase == .connected { return "Live" }
        switch hub.reachability(of: camera) {
        case .localNetwork: return "On network"
        case .online: return "Online"
        case .offline: return "Offline"
        case .unknown: return "Not seen"
        }
    }

    private var thisDevice: some View {
        SettingsSection("This device", symbol: "visionpro", footer: cloudFooter) {
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
                .cardHover(Radius.control)
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
        .frame(minHeight: VisionSize.tool)
    }
}
