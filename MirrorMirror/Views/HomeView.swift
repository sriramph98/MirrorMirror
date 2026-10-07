import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var hub: ViewerHub
    @ObservedObject private var store = RecordingStore.shared
    @State private var showCamera = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mirror").font(.largeTitle.bold())
                        Text("Mirror").font(.largeTitle.bold()).foregroundStyle(Theme.accent)
                    }
                    .padding(.top)

                    VStack(spacing: 16) {
                        Button { showCamera = true } label: {
                            HomeCard(symbol: "video.fill", title: "Use as Camera",
                                     detail: "Turn this device into a private home camera with recording, night vision, and motion & sound alerts.")
                        }
                        NavigationLink(value: "cameras") {
                            HomeCard(symbol: "eye.fill", title: "Watch",
                                     detail: watchDetail)
                        }
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: "recordings") {
                        HomeCard(symbol: "film.stack", title: "Recordings on this device",
                                 detail: store.segments.isEmpty
                                    ? "Footage this device records as a camera appears here."
                                    : "\(store.segments.count) clips · \(store.totalBytes.byteString) · \(store.events.count) events")
                    }
                    .buttonStyle(.plain)

                    PrivacyNote()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "cameras": CamerasView()
                case "recordings": RecordingsView()
                default: EmptyView()
                }
            }
        }
        .onAppear { if DebugSupport.autoStartCamera { showCamera = true } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraModeView()
        }
        .onChange(of: hub.pendingOpenCameraID) { _, id in
            // Notification tapped: jump to the camera list, which opens the camera.
            if id != nil, path.last != "cameras" { path = ["cameras"] }
        }
    }

    private var watchDetail: String {
        switch hub.cameras.count {
        case 0: "Pair a camera and watch live from anywhere, talk back, and replay recordings."
        case 1: "1 camera paired."
        default: "\(hub.cameras.count) cameras paired."
        }
    }
}

private struct HomeCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.accent)
            Text("Video streams directly between your devices, end-to-end encrypted. Recordings stay on the camera device. No accounts, no servers, no analytics.")
                .font(.footnote)
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 8)
    }
}

/// Shown when a `mirrormirror://pair` link is opened.
struct AddCameraConfirmation: View {
    let invite: PairingInvite
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Add “\(invite.name)”?").font(.title2.bold())
            Text("You'll be able to watch this camera live, talk through it, and replay its recordings. The camera's owner can remove your access at any time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                let camera = hub.add(invite)
                hub.pendingOpenCameraID = camera.id
                dismiss()
            } label: {
                Text("Add Camera").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            Button("Not Now", role: .cancel) { dismiss() }
        }
        .padding(24)
    }
}
