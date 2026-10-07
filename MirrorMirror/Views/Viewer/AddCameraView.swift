import SwiftUI

struct AddCameraView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var link = ""
    @State private var found: PairingInvite?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Method", selection: $mode) {
                    Text("Scan Code").tag(0)
                    Text("Paste Link").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let found {
                    confirmation(found)
                } else if mode == 0 {
                    QRScannerView { code in
                        if let invite = PairingInvite(string: code) { found = invite } else { error = "That isn't a MirrorMirror pairing code." }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.accent.opacity(0.6), lineWidth: 2).padding(60))
                    .padding(.horizontal)
                    Text("On the camera device, tap the QR button in camera mode.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("mirrormirror://pair?…", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Button("Paste") { link = UIPasteboard.general.string ?? "" }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("Continue") {
                                if let invite = PairingInvite(string: link) { found = invite } else { error = "That link isn't a valid pairing link." }
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            .disabled(link.isEmpty)
                        }
                        Text("The camera's owner can send you the link from camera mode › QR › Share Invite.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    Spacer()
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.vertical)
            .navigationTitle("Add Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func confirmation(_ invite: PairingInvite) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text(invite.name).font(.title2.bold())
            Text(hub.cameras.contains { $0.id == invite.key.cameraID } ? "Already added. This will update its pairing code." : "Ready to add.")
                .foregroundStyle(.secondary)
            Button {
                let camera = hub.add(invite)
                dismiss()
                hub.pendingOpenCameraID = camera.id
            } label: {
                Text("Add Camera").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
