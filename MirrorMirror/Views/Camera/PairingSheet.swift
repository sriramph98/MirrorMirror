import SwiftUI

/// How viewers get access to this camera, and who has it.
struct PairingSheet: View {
    @ObservedObject var host: CameraHost
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        QRCodeView(text: host.invite.url.absoluteString)
                            .frame(width: 220, height: 220)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        Text("On the device you'll watch from, open MirrorMirror › Watch › Add Camera and scan this code.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack {
                            ShareLink(item: host.invite.url, subject: Text("Watch \(host.settings.name)"),
                                      message: Text("Tap to add my MirrorMirror camera “\(host.settings.name)”.")) {
                                Label("Share Invite", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                UIPasteboard.general.string = host.invite.url.absoluteString
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Text("Anyone with this code or link can watch, so share it only with people you trust. Your own devices signed into the same Apple Account find this camera automatically.")
                }

                Section("Connection") {
                    LabeledContent("This network", value: "Ready")
                    LabeledContent("Away from home", value: host.remoteReady ? "Ready via iCloud" : "Needs iCloud sign-in")
                }

                Section("Watching now") {
                    if host.viewers.isEmpty {
                        Text("No one is watching").foregroundStyle(.secondary)
                    }
                    ForEach(host.viewers) { viewer in
                        HStack {
                            Image(systemName: viewer.isTalking ? "waveform.circle.fill" : "eye.circle.fill")
                                .foregroundStyle(viewer.isTalking ? Theme.accent : .green)
                            VStack(alignment: .leading) {
                                Text(viewer.name)
                                Text(viewer.isLive ? "Live" : "Watching a recording").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { host.disconnect(viewerID: viewer.viewerID) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                if !host.knownViewers.isEmpty {
                    Section {
                        ForEach(host.knownViewers) { viewer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(viewer.name).strikethrough(viewer.blocked)
                                    Text("Last seen \(viewer.lastSeen.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewer.blocked {
                                    Text("Blocked").font(.caption).foregroundStyle(.red)
                                }
                            }
                            .swipeActions {
                                Button(viewer.blocked ? "Unblock" : "Block") { host.setBlocked(viewer, blocked: !viewer.blocked) }
                                    .tint(viewer.blocked ? .green : .orange)
                                Button("Forget", role: .destructive) { host.forget(viewer) }
                            }
                        }
                    } header: {
                        Text("Devices with access")
                    } footer: {
                        Text("Swipe to block a device. Blocked devices can't connect even if they still have the code.")
                    }
                }

                Section {
                    Button("Reset Pairing Code", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Creates a new code. Every device must pair again.")
                }
            }
            .navigationTitle("Pair a Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Reset the pairing code?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { host.resetPairing() }
            } message: {
                Text("All viewers are disconnected and need the new code to watch again. Your devices on the same Apple Account update automatically.")
            }
        }
    }
}
