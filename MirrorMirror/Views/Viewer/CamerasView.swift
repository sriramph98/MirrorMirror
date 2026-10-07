import SwiftUI
import MirrorUI

/// The paired cameras as instrument cards, with rename / mute / remove in each card's context
/// menu. Used by the iPhone home screen.
struct CamerasView: View {
    @EnvironmentObject private var hub: ViewerHub
    let onOpen: (PairedCamera) -> Void

    @State private var renaming: PairedCamera?
    @State private var newName = ""
    @State private var removing: PairedCamera?

    var body: some View {
        LazyVStack(spacing: Space.m) {
            ForEach(hub.cameras) { camera in
                Button { onOpen(camera) } label: {
                    CameraCard(camera: camera, connection: hub.connection(for: camera),
                               reachability: hub.reachability(of: camera), presence: hub.presence[camera.id])
                }
                .buttonStyle(CardPressStyle())
                .contextMenu { CameraMenu(camera: camera, renaming: $renaming, newName: $newName, removing: $removing) }
            }
        }
        .cameraMenuAlerts(renaming: $renaming, newName: $newName, removing: $removing)
    }
}

/// Rename / mute / remove, shared by home cards and iPad sidebar rows.
struct CameraMenu: View {
    @EnvironmentObject private var hub: ViewerHub
    let camera: PairedCamera
    @Binding var renaming: PairedCamera?
    @Binding var newName: String
    @Binding var removing: PairedCamera?

    var body: some View {
        Button { newName = camera.name; renaming = camera } label: { Label("Rename", systemImage: "pencil") }
        Button {
            hub.setNotifications(camera, enabled: !camera.notificationsEnabled)
        } label: {
            Label(camera.notificationsEnabled ? "Mute Alerts" : "Unmute Alerts",
                  systemImage: camera.notificationsEnabled ? "bell.slash" : "bell")
        }
        Button(role: .destructive) { removing = camera } label: { Label("Remove", systemImage: "trash") }
    }
}

extension View {
    /// The rename prompt and remove confirmation that go with `CameraMenu`.
    func cameraMenuAlerts(renaming: Binding<PairedCamera?>, newName: Binding<String>, removing: Binding<PairedCamera?>) -> some View {
        modifier(CameraMenuAlerts(renaming: renaming, newName: newName, removing: removing))
    }
}

private struct CameraMenuAlerts: ViewModifier {
    @EnvironmentObject private var hub: ViewerHub
    @Binding var renaming: PairedCamera?
    @Binding var newName: String
    @Binding var removing: PairedCamera?

    func body(content: Content) -> some View {
        content
            .alert("Rename Camera", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let renaming, !newName.isEmpty { hub.rename(renaming, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(removing.map { "Remove “\($0.name)”?" } ?? "",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove Camera", role: .destructive) { if let removing { hub.remove(removing) } }
            } message: {
                Text("You can add it again later with its pairing code.")
            }
    }
}

/// Cards dip slightly when pressed, like a physical key.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
