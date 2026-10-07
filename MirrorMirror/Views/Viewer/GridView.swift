import SwiftUI

/// Every paired camera at once. Audio plays from one camera at a time.
struct GridView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @State private var focused: PairedCamera?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let columns = geo.size.width > geo.size.height ? 3 : (hub.cameras.count > 2 ? 2 : 1)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                        ForEach(hub.cameras) { camera in
                            GridTile(connection: hub.connection(for: camera), audioOn: hub.audioFocus == camera.id) {
                                hub.audioFocus = hub.audioFocus == camera.id ? "" : camera.id
                            } onOpen: {
                                focused = camera
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .background(Color.black)
            .navigationTitle("All Cameras")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            // Muted until a tile is chosen; "" means no camera has audio.
            hub.audioFocus = ""
            hub.cameras.forEach { hub.connection(for: $0).connect() }
        }
        .onDisappear {
            hub.cameras.forEach { hub.connection(for: $0).disconnect() }
            hub.audioFocus = nil
        }
        .fullScreenCover(item: $focused) { camera in
            LiveView(connection: hub.connection(for: camera), ownsConnection: false)
        }
    }
}

private struct GridTile: View {
    @ObservedObject var connection: CameraConnection
    let audioOn: Bool
    let onToggleAudio: () -> Void
    let onOpen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(sink: connection.sink, fill: true)
            switch connection.phase {
            case .connecting: ProgressView().tint(.white)
            case .failed, .rejected: Image(systemName: "video.slash").font(.title).foregroundStyle(.secondary)
            default: EmptyView()
            }
            VStack {
                HStack {
                    Text(connection.camera.name).font(.caption.weight(.semibold)).shadow(radius: 3)
                    Spacer()
                    if connection.status?.isRecording == true { Circle().fill(.red).frame(width: 7, height: 7) }
                }
                Spacer()
                HStack {
                    if let event = connection.latestEvent, Date().timeIntervalSince(event.date) < 30 {
                        Label(event.kind.title, systemImage: event.kind.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.9), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Spacer()
                    Button(action: onToggleAudio) {
                        Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.caption)
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(audioOn ? Theme.accent : Theme.stroke, lineWidth: audioOn ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
