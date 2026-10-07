import SwiftUI
import MirrorUI

/// Pair a camera by scanning its code or pasting its invite link.
struct AddCameraView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Method: String, Hashable { case scan = "Scan", link = "Link" }

    @State private var method: Method = .scan
    @State private var link = ""
    @State private var found: PairingInvite?
    @State private var error: String?
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Add camera", leadingAction: { dismiss() })
            Group {
                if let found {
                    confirmation(found)
                } else {
                    ScrollView {
                        VStack(spacing: Space.xl) {
                            SegmentPill([Method.scan, .link], selection: $method) { $0.rawValue }
                            switch method {
                            case .scan: scan
                            case .link: linkForm
                            }
                            if let error {
                                HStack(spacing: Space.s) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.live)
                                    Text(error).type(.footnote, color: Palette.textPrimary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.xs)
                            }
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
        .onChange(of: method) { _, _ in error = nil }
        .onAppear { if ScreenHook.screen == "addlink" { method = .link } }
    }

    // MARK: Scan

    private var scan: some View {
        VStack(spacing: Space.m) {
            PairingScanner { code in
                if let invite = PairingInvite(string: code) { found = invite } else { error = "That isn't a MirrorMirror pairing code." }
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
