import SwiftUI
import MirrorUI

/// Getting cameras onto this device. Two paths:
/// - Same Apple Account: nothing to do, cameras arrive through iCloud.
/// - From another device: show a short code; an iPhone/iPad/Mac that has the cameras enters it and
///   the list travels sealed through iCloud. Also accepts a pasted `mirrormirror://pair?…` link.
struct PairingSheet: View {
    enum Path: String, CaseIterable { case account = "Same Apple Account", device = "From another device" }

    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss

    @State private var path: Path = .device
    @State private var code = DevicePairing.makeCode()
    @State private var expires = Date().addingTimeInterval(DevicePairing.codeLifetime)
    @State private var receiveTask: Task<Void, Never>?
    @State private var waiting = false
    @State private var unverified = false
    @State private var added: [PairedCamera]?
    @State private var link = ""
    @State private var linkError: String?
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Pair cameras", leadingAction: { dismiss() })
            if let added {
                confirmation(added)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        SegmentPill(Path.allCases, selection: $path) { $0.rawValue }
                            .pillHover()
                            .frame(maxWidth: .infinity)
                        switch path {
                        case .account: accountPath
                        case .device: devicePath
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, Space.xl)
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 620, minHeight: 640)
        .animation(Motion.smooth, value: added?.count)
        .onAppear {
            if hub.cloudAvailable && hub.cameras.contains(where: { $0.source == .iCloud }) { path = .account }
            startReceiving()
        }
        .onDisappear { receiveTask?.cancel() }
    }

    // MARK: Same Apple Account

    private var accountPath: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SettingsSection("iCloud", symbol: "icloud.fill",
                            footer: "Any iPhone or iPad signed in to the same Apple Account that runs MirrorMirror as a camera is added here on its own. Nothing to type.") {
                SettingRow("Status") {
                    LED(hub.cloudAvailable ? Palette.ok : Palette.textTertiary, label: hub.cloudAvailable ? "Signed in" : "Not signed in")
                }
                ValueRow("Cameras from iCloud", value: "\(hub.cameras.filter { $0.source == .iCloud }.count)")
                SettingRow("Check again", detail: "Looks for cameras that were just set up") {
                    Button { hub.activate() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pill())
                        .pillHover()
                }
            }
            if !hub.cloudAvailable {
                Text("Sign in to iCloud in Settings on this Vision Pro, or use the code on the other tab.")
                    .type(.footnote, color: Palette.textTertiary)
                    .padding(.horizontal, Space.xs)
            }
        }
    }

    // MARK: From another device

    private var devicePath: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            codePanel
            SettingsSection("Or paste an invite link", symbol: "link") {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.m) {
                        TextField("mirrormirror://pair?…", text: $link, axis: .vertical)
                            .type(.readoutLarge)
                            .lineLimit(1...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($linkFocused)
                            .onSubmit(addLink)
                        Button {
                            link = UIPasteboard.general.string ?? ""
                            linkError = nil
                        } label: { Image(systemName: "doc.on.clipboard") }
                            .buttonStyle(.tool(size: VisionSize.toolSmall))
                            .toolHover()
                            .accessibilityLabel("Paste")
                        Button("Add", action: addLink)
                            .buttonStyle(.pill(isOn: !link.isEmpty))
                            .pillHover()
                            .disabled(link.isEmpty)
                    }
                    if let linkError {
                        HStack(spacing: Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.live)
                            Text(linkError).type(.footnote, color: Palette.textPrimary)
                        }
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
            }
        }
    }

    private var codePanel: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your code").type(.caps)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, expires.timeIntervalSince(context.date))
                    ReadoutLine([remaining > 0 ? String(format: "%d:%02d left", Int(remaining) / 60, Int(remaining) % 60) : "Expired"],
                                color: remaining < 60 ? Palette.warn : Palette.textSecondary)
                }
            }
            Text(DevicePairing.formatted(code))
                .font(.custom(Fonts.groteskBold, size: 72, relativeTo: .largeTitle))
                .tracking(6)
                .monospacedDigit()
                .foregroundStyle(unverified ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.m)
                .focusBrackets(Palette.textTertiary, length: 20, lineWidth: 1.5, inset: Space.s)
                .accessibilityLabel("Pairing code")
                .accessibilityValue(code.map(String.init).joined(separator: " "))

            Text("On an iPhone, iPad or Mac that has the cameras, open MirrorMirror › Settings › Pair Apple TV or Vision Pro and enter this code.")
                .type(.callout, color: Palette.textSecondary)

            HStack(spacing: Space.m) {
                if unverified {
                    LED(Palette.warn, label: hub.cloudAvailable ? "Code expired" : "Can't verify")
                } else if waiting {
                    LED(Palette.accent, label: "Waiting for a device", pulsing: true)
                }
                Spacer(minLength: Space.s)
                Button { newCode() } label: { Label("New code", systemImage: "arrow.clockwise") }
                    .buttonStyle(.pill(isOn: unverified))
                    .pillHover()
            }
            if unverified {
                Text(hub.cloudAvailable
                     ? "No device entered the code before it expired. Make a new code and try again."
                     : "This Vision Pro isn't signed in to iCloud, so the code can't be verified end-to-end. Sign in, or paste an invite link below.")
                    .type(.footnote, color: Palette.textTertiary)
            }
        }
        .panel(padding: Space.xl)
    }

    private func newCode() {
        code = DevicePairing.makeCode()
        expires = Date().addingTimeInterval(DevicePairing.codeLifetime)
        startReceiving()
    }

    private func startReceiving() {
        receiveTask?.cancel()
        unverified = false
        waiting = true
        let current = code
        receiveTask = Task {
            let payload = await DevicePairing.receive(code: current)
            guard !Task.isCancelled, current == code else { return }
            waiting = false
            if let payload {
                added = payload.cameras.map { hub.add(PairingInvite(key: $0.key, name: $0.name)) }
            } else if hub.cloudAvailable, Date() >= expires {
                // The code ran out while nobody entered it: show a fresh one and keep waiting.
                newCode()
            } else {
                // iCloud isn't available on this device, so the mailbox can't be checked.
                unverified = true
            }
        }
    }

    private func addLink() {
        if let invite = PairingInvite(string: link) {
            added = [hub.add(invite)]
            linkError = nil
        } else {
            linkError = "That isn't a MirrorMirror pairing link."
        }
    }

    // MARK: Done

    private func confirmation(_ cameras: [PairedCamera]) -> some View {
        VStack(spacing: Space.xl) {
            Spacer(minLength: 0)
            EmptyState(symbol: "checkmark.viewfinder",
                       title: cameras.count == 1 ? cameras[0].name : "\(cameras.count) cameras added",
                       message: cameras.count == 1 ? "Ready to watch. Open it from the browser or place it in its own window."
                                                  : cameras.map(\.name).joined(separator: ", ")) {
                VStack(spacing: Space.s) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.primary)
                        .cardHover(Radius.control)
                    Button("Pair more") { added = nil; newCode() }
                        .buttonStyle(.pill())
                        .pillHover()
                }
                .padding(.top, Space.s)
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }
}
