import CloudKit
import SwiftUI
import MirrorUI

/// How viewers get access to this camera, and who has it.
struct PairingSheet: View {
    @ObservedObject var host: CameraHost
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var copied = false
    /// The code for adding this camera from anywhere; exists only while this screen is open.
    @State private var code: String?
    @State private var codeRecord: CKRecord.ID?

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
        // A new code whenever iCloud comes up or the pairing key is reset.
        .task(id: "\(host.remoteReady)-\(host.key.mailbox)") { await rotateCodes() }
        .onDisappear(perform: retireCode)
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
                .accessibilityHint("Scan with Mira on the device you'll watch from")

            VStack(spacing: Space.xs) {
                Text(host.settings.name).type(.title).multilineTextAlignment(.center)
                Text("On the device you'll watch from, open Mira, tap + and scan this code. Devices on this Wi-Fi also find “\(host.settings.name)” under Nearby.")
                    .type(.callout, color: Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            codeBlock

            // Mac: the link itself, selectable, for people who'd rather copy a part of it or
            // drag it into a message.
            if Platform.isMac {
                Text(host.invite.url.absoluteString)
                    .font(.custom(Fonts.monoMedium, size: 12, relativeTo: .caption))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity)
                    .background(Palette.frame, in: .continuous(Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    .accessibilityLabel("Pairing link")
            }

            VStack(spacing: Space.s) {
                ShareLink(item: host.invite.url, subject: Text("Watch \(host.settings.name)"),
                          message: Text("Tap to add my Mira camera “\(host.settings.name)”.")) {
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

    // MARK: Code

    private var codeBlock: some View {
        VStack(spacing: Space.s) {
            Text("Or type this code").type(.caps)
            if let code {
                CodePlate(CameraCode.formatted(code), size: 32)
                Text("Works from anywhere while this screen is open, and changes every few minutes.")
                    .type(.footnote, color: Palette.textTertiary)
                    .multilineTextAlignment(.center)
            } else if host.remoteReady {
                ProgressView().tint(Palette.accent).padding(Space.l)
            } else {
                Text("Codes need iCloud on this camera. Devices on this Wi-Fi can still add it under Nearby, or scan the QR code.")
                    .type(.footnote, color: Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rotateCodes() async {
        retireCode()
        guard host.remoteReady else { return }
        while !Task.isCancelled {
            let next = CameraCode.makeCode()
            guard let record = try? await CameraCode.publish(host.invite, code: next), !Task.isCancelled else { return }
            retireCode()
            codeRecord = record
            code = next
            try? await Task.sleep(for: .seconds(CameraCode.lifetime))
        }
    }

    private func retireCode() {
        if let record = codeRecord { Task { await CloudRelay.shared.delete([record]) } }
        codeRecord = nil
        code = nil
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
