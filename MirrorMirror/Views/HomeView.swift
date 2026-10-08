import SwiftUI
import MirrorUI

/// iPhone home: wordmark, camera cards, and a deck with Use as Camera, Recordings and Settings.
struct HomeView: View {
    @EnvironmentObject private var hub: ViewerHub
    @ObservedObject private var store = RecordingStore.shared
    @Binding var showCamera: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    @State private var path: [HomeRoute] = []
    @State private var openCamera: PairedCamera?
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showWall = false

    enum HomeRoute: Hashable { case recordings }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    camerasSection
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
            .refreshable { await hub.refreshPresence() }
            .safeAreaInset(edge: .bottom, spacing: 0) { deck }
            .canvasBackground(Palette.frame)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .recordings:
                    RecordingsView(onClose: { path.removeLast() })
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddCameraView().mirrorSheet() }
        .sheet(isPresented: $showSettings) { ViewerSettingsView(onClose: { showSettings = false }).mirrorSheet() }
        .fullScreenCover(isPresented: $showWall) { GridView() }
        .fullScreenCover(item: $openCamera) { camera in
            LiveView(connection: hub.connection(for: camera), onClose: { openCamera = nil })
        }
        .onAppear {
            openPending()
            switch ScreenHook.screen {
            case "add", "addlink": showAdd = true
            case "settings", "gallery": showSettings = true
            case "recordings", "player": path = [.recordings]
            case "wall": showWall = true
            default: break
            }
        }
        .onChange(of: hub.pendingOpenCameraID) { _, _ in openPending() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.m) {
            Wordmark(size: 15)
            Spacer(minLength: Space.s)
            Button { showAdd = true } label: { Image(systemName: "plus") }
                .buttonStyle(.tool())
                .accessibilityLabel("Add camera")
        }
        .padding(.top, Space.s)
    }

    // MARK: Cameras

    @ViewBuilder
    private var camerasSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("Cameras").type(.caps)
                if !hub.cameras.isEmpty {
                    Text("\(hub.cameras.count)").type(.readout, color: Palette.textTertiary)
                }
                Spacer(minLength: Space.s)
                if hub.cameras.count >= 2 {
                    Button { showWall = true } label: {
                        Label("All cameras", systemImage: "square.grid.2x2.fill")
                    }
                    .buttonStyle(.pill())
                }
            }
            .padding(.horizontal, Space.xs)
            .frame(minHeight: ControlSize.tool)

            if hub.cameras.isEmpty {
                EmptyState(symbol: "video.badge.plus", title: "No cameras yet",
                           message: "Open MirrorMirror on a spare iPhone or iPad and tap Use as camera. Cameras on your Apple Account appear here on their own; for anyone else's, scan its pairing code.") {
                    VStack(spacing: Space.s) {
                        Button { showAdd = true } label: { Label("Add camera", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(.accent)
                        Button { showCamera = true } label: { Text("Use this iPhone as a camera") }
                            .buttonStyle(.pill())
                    }
                    .padding(.top, Space.s)
                }
                .frame(maxWidth: .infinity)
                .panel()
            } else {
                CamerasView { openCamera = $0 }
            }
        }
    }

    // MARK: Deck

    private var deck: some View {
        VStack(spacing: Space.m) {
            if dynamicType.isAccessibilitySize {
                // Large type: the primary action gets the full width, tools sit under it.
                useAsCamera
                HStack(alignment: .top) {
                    recordingsTool
                    Spacer()
                    settingsTool
                }
            } else {
                HStack(alignment: .top, spacing: Space.m) {
                    recordingsTool
                    useAsCamera.padding(.top, Space.xxs)
                    settingsTool
                }
            }
            HStack(spacing: Space.s) {
                Image(systemName: "lock.fill").font(.caption2.weight(.bold)).foregroundStyle(Palette.textTertiary)
                ViewThatFits {
                    ReadoutLine(["P2P", "End-to-end", "No cloud video"], color: Palette.textTertiary)
                    ReadoutLine(["P2P", "E2E", "No cloud"], color: Palette.textTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Peer to peer, end-to-end encrypted, no cloud video")
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.s)
        .readableWidth()
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Radius.deck, topTrailingRadius: Radius.deck, style: .continuous)
                .fill(Palette.surface)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: Radius.deck, topTrailingRadius: Radius.deck, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: 1)
                        .mask(LinearGradient(colors: [Palette.textPrimary, .clear], startPoint: .top, endPoint: .center))
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var useAsCamera: some View {
        Button { showCamera = true } label: {
            Label("Use as camera", systemImage: "video.fill")
        }
        .buttonStyle(.primary)
    }

    private var recordingsTool: some View {
        deckTool(symbol: "film.stack", caption: recordingsCaption, label: "Recordings", value: recordingsValue) {
            path.append(.recordings)
        }
    }

    private var settingsTool: some View {
        deckTool(symbol: "gearshape", caption: "Settings", label: "Settings", value: nil) { showSettings = true }
    }

    private func deckTool(symbol: String, caption: String, label: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: ControlSize.toolLarge, height: ControlSize.toolLarge)
                    .background(Palette.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                Text(caption).type(.readout, color: Palette.textSecondary).lineLimit(1).fixedSize()
            }
            .frame(minWidth: ControlSize.toolLarge + Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }

    private var recordingsCaption: String {
        store.segments.isEmpty ? "Clips" : "\(store.segments.count) · \(store.totalBytes.byteString)"
    }

    private var recordingsValue: String {
        store.segments.isEmpty ? "None on this device"
            : "\(store.segments.count) clips, \(store.totalBytes.byteString)"
    }

    // MARK: Deep links

    private func openPending() {
        guard let id = hub.pendingOpenCameraID, let camera = hub.camera(id: id) else { return }
        hub.pendingOpenCameraID = nil
        // Already watching it (e.g. Talk on the Lock Screen): keep the connection, don't reopen.
        if openCamera?.id == id, !showAdd, !showSettings, !showWall { return }
        let covered = showAdd || showSettings || showWall || openCamera != nil
        showAdd = false
        showSettings = false
        showWall = false
        if covered {
            openCamera = nil
            // Let the current sheet or cover finish dismissing before presenting the camera.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                openCamera = camera
            }
        } else {
            openCamera = camera
        }
    }
}

/// Shown when a `mirrormirror://pair` link is opened.
struct AddCameraConfirmation: View {
    let invite: PairingInvite
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Add camera", leadingAction: { dismiss() })
            Spacer(minLength: 0)
            EmptyState(symbol: "video.badge.plus", title: "Add “\(invite.name)”?",
                       message: "You'll be able to watch this camera live, talk through it and replay its recordings. Its owner can remove your access at any time.") {
                VStack(spacing: Space.s) {
                    Button {
                        let camera = hub.add(invite)
                        dismiss()
                        // Open it once this sheet has gone, so the live view can present.
                        Task { @MainActor [hub] in
                            try? await Task.sleep(for: .milliseconds(600))
                            hub.pendingOpenCameraID = camera.id
                        }
                    } label: { Text("Add camera") }
                    .buttonStyle(.primary)
                    Button("Not now") { dismiss() }
                        .buttonStyle(.pill())
                }
                .padding(.top, Space.s)
            }
            Spacer(minLength: 0)
        }
        .readableWidth()
        .canvasBackground()
    }
}
