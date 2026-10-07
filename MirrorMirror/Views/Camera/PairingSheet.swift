import SwiftUI
import MirrorUI

/// How viewers get access to this camera, and who has it.
struct PairingSheet: View {
    @ObservedObject var host: CameraHost
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Pair a viewer", leadingAction: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    invite
                    connectionSection
                    watchingSection
                    if !host.knownViewers.isEmpty { devicesSection }
                    resetSection
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
        }
        .canvasBackground()
        .confirmationDialog("Reset the pairing code?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { host.resetPairing() }
        } message: {
            Text("All viewers are disconnected and need the new code to watch again. Your devices on the same Apple Account update automatically.")
        }
    }

    // MARK: Invite

    /// Big enough to scan from arm's length, small enough to leave the actions on screen.
    private static let codeSize = ControlSize.shutter * 3

    private var invite: some View {
        VStack(spacing: Space.l) {
            QRCodeView(text: host.invite.url.absoluteString)
                .blendMode(.multiply) // lets the plate's warm white show through the code's white
                .frame(width: Self.codeSize, height: Self.codeSize)
                .padding(Space.l)
                .background(Palette.textPrimary, in: .continuous(Radius.panel))
                .focusBrackets(Palette.accent, length: Space.xl, inset: -Space.m)
                .padding(Space.m)
                .accessibilityElement()
                .accessibilityLabel("Pairing code for \(host.settings.name)")
                .accessibilityHint("Scan with MirrorMirror on the device you'll watch from")

            VStack(spacing: Space.xs) {
                Text(host.settings.name).type(.title).multilineTextAlignment(.center)
                Text("On the device you'll watch from, open MirrorMirror › Watch › Add Camera and scan this code.")
                    .type(.callout, color: Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Space.s) {
                ShareLink(item: host.invite.url, subject: Text("Watch \(host.settings.name)"),
                          message: Text("Tap to add my MirrorMirror camera “\(host.settings.name)”.")) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary)

                Button {
                    UIPasteboard.general.string = host.invite.url.absoluteString
                    withAnimation(Motion.snappy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.secondary)
                .sensoryFeedback(.success, trigger: copied)
            }

            Text("Anyone with this code or link can watch, so share it only with people you trust. Your own devices signed into the same Apple Account find this camera automatically.")
                .type(.footnote, color: Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sections

    private var connectionSection: some View {
        SettingsSection("Connection", symbol: "antenna.radiowaves.left.and.right") {
            SettingRow("This network", symbol: "wifi") {
                LED(Palette.ok, label: "READY")
            }
            SettingRow("Away from home", detail: host.remoteReady ? "Via iCloud" : "Sign in to iCloud on this device", symbol: "globe") {
                LED(host.remoteReady ? Palette.ok : Palette.warn, label: host.remoteReady ? "READY" : "OFF")
            }
        }
    }

    private var watchingSection: some View {
        SettingsSection("Watching now", symbol: "eye") {
            if host.viewers.isEmpty {
                SettingRow("No one is watching", symbol: "eye.slash")
            }
            ForEach(host.viewers) { viewer in
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(viewer.name).type(.body)
                        viewerLED(viewer)
                    }
                    Spacer(minLength: Space.s)
                    Button("Disconnect") { host.disconnect(viewerID: viewer.viewerID) }
                        .buttonStyle(.pill())
                        .accessibilityLabel("Disconnect \(viewer.name)")
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
            }
        }
    }

    private func viewerLED(_ viewer: CameraHost.ViewerSummary) -> some View {
        if viewer.isTalking { return LED(Palette.accent, label: "TALKING", pulsing: true) }
        if viewer.isLive { return LED(Palette.live, label: "LIVE", pulsing: true) }
        return LED(Palette.info, label: "PLAYBACK")
    }

    private var devicesSection: some View {
        SettingsSection("Devices with access", symbol: "person.2",
                        footer: "Blocked devices can't connect even if they still have the code.") {
            ForEach(host.knownViewers) { viewer in
                HStack(spacing: Space.m) {
                    LED(viewer.blocked ? Palette.textTertiary : Palette.ok)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(viewer.name)
                            .type(.body, color: viewer.blocked ? Palette.textTertiary : Palette.textPrimary)
                            .strikethrough(viewer.blocked)
                        Text("Last seen \(viewer.lastSeen.formatted(.relative(presentation: .named)))")
                            .type(.footnote, color: Palette.textTertiary)
                    }
                    Spacer(minLength: Space.s)
                    if viewer.blocked { Badge("BLOCKED") }
                    Menu {
                        deviceActions(viewer)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: ControlSize.tool, height: ControlSize.tool)
                            .background(Palette.raised, in: Circle())
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .accessibilityLabel("Options for \(viewer.name)")
                }
                .padding(.leading, Space.l)
                .padding(.trailing, Space.m)
                .padding(.vertical, Space.s)
                .contentShape(Rectangle())
                .contextMenu { deviceActions(viewer) }
                .accessibilityElement(children: .contain)
                .accessibilityValue(viewer.blocked ? "Blocked" : "Allowed")
            }
        }
    }

    @ViewBuilder
    private func deviceActions(_ viewer: KnownViewer) -> some View {
        Button {
            host.setBlocked(viewer, blocked: !viewer.blocked)
        } label: {
            Label(viewer.blocked ? "Unblock" : "Block", systemImage: viewer.blocked ? "checkmark.circle" : "nosign")
        }
        Button(role: .destructive) {
            host.forget(viewer)
        } label: {
            Label("Forget", systemImage: "trash")
        }
    }

    private var resetSection: some View {
        SettingsSection(footer: "Creates a new code. Every device must pair again.") {
            Button(role: .destructive) { confirmReset = true } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body.weight(.semibold))
                        .frame(width: Space.xl)
                    Text("Reset pairing code").type(.body, color: Palette.live)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.live)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .frame(minHeight: ControlSize.toolLarge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
