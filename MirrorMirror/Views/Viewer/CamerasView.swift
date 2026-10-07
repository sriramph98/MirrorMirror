import SwiftUI

struct CamerasView: View {
    @EnvironmentObject private var hub: ViewerHub
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var openCamera: PairedCamera?
    @State private var showGrid = false
    @State private var renaming: PairedCamera?
    @State private var newName = ""

    var body: some View {
        Group {
            if hub.cameras.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(hub.cameras) { camera in
                            Button { openCamera = camera } label: {
                                CameraRow(camera: camera, reachability: hub.reachability(of: camera), presence: hub.presence[camera.id])
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: camera) }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await hub.refreshPresence() }
            }
        }
        .navigationTitle("Cameras")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if hub.cameras.count > 1 {
                    Button { showGrid = true } label: { Image(systemName: "square.grid.2x2") }
                        .accessibilityLabel("Watch all")
                }
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add camera")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Viewer settings")
            }
        }
        .sheet(isPresented: $showAdd) { AddCameraView() }
        .sheet(isPresented: $showSettings) { ViewerSettingsView() }
        .fullScreenCover(item: $openCamera) { camera in
            LiveView(connection: hub.connection(for: camera))
        }
        .fullScreenCover(isPresented: $showGrid) { GridView() }
        .alert("Rename Camera", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let renaming { hub.rename(renaming, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            hub.activate()
            Notifications.requestAuthorization()
            openPending()
        }
        .onChange(of: hub.pendingOpenCameraID) { _, _ in openPending() }
    }

    private func openPending() {
        guard let id = hub.pendingOpenCameraID, let camera = hub.camera(id: id) else { return }
        hub.pendingOpenCameraID = nil
        openCamera = camera
    }

    @ViewBuilder
    private func menu(for camera: PairedCamera) -> some View {
        Button { newName = camera.name; renaming = camera } label: { Label("Rename", systemImage: "pencil") }
        Button {
            hub.setNotifications(camera, enabled: !camera.notificationsEnabled)
        } label: {
            Label(camera.notificationsEnabled ? "Mute Alerts" : "Unmute Alerts",
                  systemImage: camera.notificationsEnabled ? "bell.slash" : "bell")
        }
        Button(role: .destructive) { hub.remove(camera) } label: { Label("Remove", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "video.badge.plus").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text("No cameras yet").font(.title2.bold())
            Text("On your spare iPhone or iPad, open MirrorMirror and tap Use as Camera. Devices on your Apple Account show up here automatically; for anyone else's camera, scan its pairing code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button { showAdd = true } label: {
                Label("Add Camera", systemImage: "qrcode.viewfinder").font(.headline).padding(.horizontal, 12).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            Spacer()
            Spacer()
        }
    }
}

private struct CameraRow: View {
    let camera: PairedCamera
    let reachability: ViewerHub.Reachability
    let presence: PresenceInfo?

    var body: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Circle().fill(dotColor).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(camera.name).font(.headline)
                    if !camera.notificationsEnabled { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let presence {
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: batterySymbol(presence.batteryLevel, charging: presence.isCharging))
                    if presence.isRecording { Text("REC").font(.caption2.bold()).foregroundStyle(.red) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        switch reachability {
        case .localNetwork, .online: .green
        case .offline: .gray
        case .unknown: .orange
        }
    }

    private var statusText: String {
        switch reachability {
        case .localNetwork: return "On this network"
        case .online: return "Online"
        case let .offline(date):
            if let date { return "Last seen \(date.formatted(.relative(presentation: .named)))" }
            return "Not on this network"
        case .unknown: return "Not on this network · iCloud off"
        }
    }
}
