import SwiftUI
import MirrorUI

/// Pair a camera: pick it from the cameras on this network and type the code it shows, or scan
/// its QR code, type the code on its Pair screen (works from anywhere), or paste its link.
struct AddCameraView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Method: String, Hashable { case scan = "Scan", code = "Code", link = "Link" }

    // A Mac's camera points at the person, not at another device's screen: start on the code.
    @State private var method: Method = Platform.isMac ? .code : .scan
    @State private var link = ""
    @State private var found: PairingInvite?
    @State private var error: String?
    @FocusState private var linkFocused: Bool

    // Nearby
    @StateObject private var nearby = NearbyCameraBrowser()
    @State private var reaching: String?
    @State private var session: NearbyPairingSession?
    @State private var nearbyCode = ""
    @State private var checking = false

    // Code from anywhere
    @State private var cameraCode = ""
    @State private var lookingUp = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Add camera", leadingAction: { dismiss() })
            Group {
                if let found {
                    confirmation(found)
                } else if let session {
                    nearbyCodeEntry(session)
                } else {
                    ScrollView {
                        VStack(spacing: Space.xl) {
                            nearbySection
                            VStack(spacing: Space.l) {
                                SegmentPill([Method.scan, .code, .link], selection: $method) { $0.rawValue }
                                switch method {
                                case .scan: scan
                                case .code: codeForm
                                case .link: linkForm
                                }
                            }
                            if let error { errorLine(error) }
                        }
                        .padding(.horizontal, Space.l)
                        .padding(.bottom, Space.xl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .readableWidth()
        }
        .canvasBackground()
        .animation(Motion.smooth, value: found != nil)
        .animation(Motion.smooth, value: session != nil)
        .onChange(of: method) { _, _ in error = nil }
        .onAppear {
            nearby.start()
            if ScreenHook.screen == "addlink" { method = .link }
            if ScreenHook.screen == "addcode" { method = .code }
        }
        .onDisappear {
            nearby.stop()
            session?.cancel()
        }
    }

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.live)
            Text(text).type(.footnote, color: Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
    }

    private func add(_ invite: PairingInvite) {
        let camera = hub.add(invite)
        hub.pendingOpenCameraID = camera.id
        dismiss()
    }

    // MARK: Nearby

    /// Cameras in camera mode on this network (not this device's own camera).
    private var nearbyCameras: [NearbyCamera] { nearby.cameras.filter { $0.id != DeviceIdentity.id } }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("Nearby").type(.caps)
                Spacer(minLength: Space.s)
                if nearby.isBrowsing { ProgressView().controlSize(.small).tint(Palette.textTertiary) }
            }
            .padding(.horizontal, Space.xs)

            VStack(spacing: 0) {
                if nearbyCameras.isEmpty {
                    Text("Looking for cameras on this Wi-Fi. Open camera mode on the other device and it appears here.")
                        .type(.footnote, color: Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.l)
                } else {
                    ForEach(nearbyCameras) { camera in
                        nearbyRow(camera)
                        if camera.id != nearbyCameras.last?.id { Divider().overlay(Palette.hairline).padding(.leading, Space.l) }
                    }
                }
            }
            .background(Palette.surface, in: .continuous(Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    private func nearbyRow(_ camera: NearbyCamera) -> some View {
        let added = hub.cameras.contains { $0.id == camera.id }
        return Button { startNearby(camera) } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "video.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: Space.xl)
                Text(camera.name).type(.headline).lineLimit(1)
                Spacer(minLength: Space.s)
                if reaching == camera.id {
                    ProgressView().tint(Palette.accent)
                } else {
                    if added { Badge("ADDED") }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(minHeight: ControlSize.toolLarge)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reaching != nil)
        .accessibilityLabel(camera.name)
        .accessibilityValue(added ? "Already added" : "")
        .accessibilityHint("Shows a code on the camera to type here")
    }

    private func startNearby(_ camera: NearbyCamera) {
        error = nil
        reaching = camera.id
        Task {
            do {
                nearbyCode = ""
                session = try await NearbyPairingSession.begin(with: camera)
            } catch {
                self.error = error.localizedDescription
            }
            reaching = nil
        }
    }

    private func nearbyCodeEntry(_ session: NearbyPairingSession) -> some View {
        ScrollView {
            VStack(spacing: Space.l) {
                Image(systemName: "number")
                    .font(.system(size: ControlSize.tool * 0.6, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: ControlSize.toolLarge, height: ControlSize.toolLarge)
                    .focusBrackets(Palette.accent, length: Space.m)
                    .padding(.top, Space.xl)
                VStack(spacing: Space.xs) {
                    Text("Type the code on \(session.cameraName)").type(.title).multilineTextAlignment(.center)
                    Text("It's on the camera's screen now. It works once and never leaves your devices.")
                        .type(.callout, color: Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                CodeField("000 000", text: $nearbyCode, numeric: true)
                    .frame(maxWidth: ControlSize.readableWidth / 2)
                    .disabled(checking)
                    // Submits once all six digits are in. A task keyed on the text sees the final
                    // value even when fast typing or a pasted code coalesces the change events.
                    .task(id: nearbyCode) {
                        if NearbyPairing.normalize(nearbyCode).count == NearbyPairing.codeLength { submitNearby(session) }
                    }
                if let error { errorLine(error) }
                let complete = NearbyPairing.normalize(nearbyCode).count == NearbyPairing.codeLength
                Button(checking ? "Checking…" : "Add camera") { submitNearby(session) }
                    .buttonStyle(.primary)
                    .disabled(checking || !complete)
                    .opacity(complete ? 1 : 0.4)
                Button("Cancel") {
                    session.cancel()
                    self.session = nil
                }
                .buttonStyle(.pill())
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
        .transition(.opacity)
    }

    private func submitNearby(_ session: NearbyPairingSession) {
        guard !checking else { return }
        checking = true
        error = nil
        let code = nearbyCode
        Task {
            do {
                let invite = try await session.complete(code: code)
                checking = false
                add(invite)
            } catch {
                checking = false
                // Every attempt uses a new code, so any failure goes back to the list.
                self.error = error.localizedDescription
                self.session = nil
            }
        }
    }

    // MARK: Code (from anywhere)

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Camera code").type(.caps)
                CodeField("ABCD-2345", text: $cameraCode, numeric: false)
            }
            .panel()

            Button(lookingUp ? "Looking…" : "Continue") { lookUp() }
                .buttonStyle(.primary)
                .disabled(lookingUp || !CameraCode.isValid(cameraCode))
                .opacity(CameraCode.isValid(cameraCode) ? 1 : 0.4)

            Text("On the camera, open camera mode › pairing. The code under the QR works from anywhere while that screen is open.")
                .type(.footnote, color: Palette.textTertiary)
                .padding(.horizontal, Space.xs)
        }
    }

    private func lookUp() {
        lookingUp = true
        error = nil
        Task {
            do {
                found = try await CameraCode.lookUp(cameraCode)
            } catch {
                self.error = error.localizedDescription
            }
            lookingUp = false
        }
    }

    // MARK: Scan

    private var scan: some View {
        VStack(spacing: Space.m) {
            PairingScanner { code in
                if let invite = PairingInvite(string: code) { found = invite } else { error = "That isn't a Mira pairing code." }
            } onUseLink: {
                method = .link
            }
            // Portrait on iPhone; square in the shorter iPad form sheet.
            .aspectRatio(sizeClass == .regular ? 1 : 3 / 4, contentMode: .fit)
            Text("On the camera device, tap the pairing button in camera mode.")
                .type(.footnote, color: Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Link

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Pairing link").type(.caps)
                    Spacer()
                    Button {
                        link = UIPasteboard.general.string ?? ""
                        error = nil
                    } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.pill())
                }
                TextField("mirrormirror://pair?…", text: $link, axis: .vertical)
                    .type(.readoutLarge)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($linkFocused)
                    .padding(Space.m)
                    .background(Palette.frame, in: .continuous(Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(linkFocused ? Palette.accent : Palette.hairline, lineWidth: 1))
            }
            .panel()

            Button("Continue") {
                if let invite = PairingInvite(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    found = invite
                } else {
                    error = "That link isn't a valid pairing link."
                }
            }
            .buttonStyle(.primary)
            .disabled(link.isEmpty)
            .opacity(link.isEmpty ? 0.4 : 1)

            Text("The camera's owner can send you the link from camera mode › pairing › Share Invite.")
                .type(.footnote, color: Palette.textTertiary)
                .padding(.horizontal, Space.xs)
        }
    }

    // MARK: Confirm

    private func confirmation(_ invite: PairingInvite) -> some View {
        let existing = hub.cameras.contains { $0.id == invite.key.cameraID }
        return VStack {
            Spacer(minLength: 0)
            EmptyState(symbol: "checkmark.viewfinder", title: invite.name,
                       message: existing ? "Already added. Adding it again updates its pairing code."
                                         : "Ready to add. You'll be able to watch live, talk through it and replay its recordings.") {
                VStack(spacing: Space.s) {
                    Button(existing ? "Update camera" : "Add camera") {
                        let camera = hub.add(invite)
                        hub.pendingOpenCameraID = camera.id
                        dismiss()
                    }
                    .buttonStyle(.primary)
                    Button("Scan again") { found = nil }
                        .buttonStyle(.pill())
                }
                .padding(.top, Space.s)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }
}
