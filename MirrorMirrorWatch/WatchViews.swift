import SwiftUI
import MirrorUI

@main
struct MirrorMirrorWatchApp: App {
    init() { Fonts.register() }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(WatchStore.shared)
                .tint(Palette.accent)
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        NavigationStack {
            Group {
                if store.cameras.isEmpty {
                    ScrollView {
                        VStack(spacing: Space.m) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.title2)
                                .foregroundStyle(Palette.accent)
                                .frame(width: 52, height: 52)
                                .focusBrackets(Palette.textTertiary, length: 10, lineWidth: 1.5, inset: 0)
                            Text("No cameras").type(.headline)
                            Text("Add cameras in Mira on your iPhone. They appear here automatically.")
                                .type(.footnote, color: Palette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, Space.l)
                    }
                } else {
                    List(store.cameras) { camera in
                        NavigationLink(value: camera.id) {
                            CameraRow(camera: camera)
                        }
                        .listRowBackground(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.surface))
                    }
                    .listStyle(.carousel)
                }
            }
            .navigationTitle("Cameras")
            .navigationDestination(for: String.self) { id in
                CameraPager(initialID: id)
            }
        }
        .task { await debugAutomation() }
    }

    /// Debug-only: `-MMWatchTalkTest` opens the first camera and holds talk for 3 s once live
    /// (simulated touches on the watch simulator are unreliable for press-and-hold).
    private func debugAutomation() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-MMWatchTalkTest") else { return }
        for _ in 0..<20 where store.cameras.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        guard let camera = store.cameras.first else { return }
        store.open(camera)
        for _ in 0..<20 where store.source != .iPhone { try? await Task.sleep(for: .seconds(1)) }
        watchDebugLog("MM watch: test talking, source=%@", String(describing: store.source))
        store.setTalking(true)
        try? await Task.sleep(for: .seconds(3))
        store.setTalking(false)
        watchDebugLog("MM watch: test talk done")
        #endif
    }
}

private struct CameraRow: View {
    let camera: WatchCamera
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(camera.name).type(.headline).lineLimit(2)
            LED(store.phoneReachable ? Palette.ok : Palette.info, label: store.phoneReachable ? "Via iPhone" : "iCloud")
        }
        .padding(.vertical, Space.s)
    }
}

/// One page per camera; the Digital Crown pages between them.
struct CameraPager: View {
    @EnvironmentObject private var store: WatchStore
    @State private var selection: String

    init(initialID: String) { _selection = State(initialValue: initialID) }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(store.cameras) { camera in
                WatchLiveView(camera: camera, isCurrent: selection == camera.id)
                    .tag(camera.id)
            }
        }
        .tabViewStyle(.verticalPage)
        .onAppear { open(selection) }
        .onChange(of: selection) { _, id in open(id) }
        .onDisappear { store.close() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func open(_ id: String) {
        if let camera = store.cameras.first(where: { $0.id == id }) { store.open(camera) }
    }
}

struct WatchLiveView: View {
    let camera: WatchCamera
    let isCurrent: Bool
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        // The picture is a background so its fill-scaling can't widen the layout of the controls.
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Palette.frame
                picture
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var picture: some View {
        if isCurrent, let frame = store.frame {
            GeometryReader { geo in
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.7)],
                                    startPoint: .top, endPoint: .bottom))
        } else {
            VStack(spacing: Space.s) {
                ProgressView().tint(Palette.accent)
                Text(store.status?.detail ?? "Connecting…").type(.readout)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(camera.name).type(.caps, color: Palette.textPrimary).lineLimit(1)
            HStack(spacing: Space.s) {
                switch store.source {
                case .iPhone:
                    LED(Palette.live, label: "Live", pulsing: true)
                case .iCloud:
                    Badge(snapshotAge, style: .outline)
                case .none:
                    LED(Palette.textTertiary, label: "Wait")
                }
                if store.status?.isRecording == true { Badge("Rec", style: .recording) }
                if let battery = store.status?.batteryLevel {
                    Text("\(Int(battery * 100))%").type(.readout, color: battery < 0.2 ? Palette.warn : Palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.xs)
    }

    private var snapshotAge: String {
        guard let date = store.frameDate else { return "Snapshot" }
        return "Still · \(max(0, Int(Date().timeIntervalSince(date))))s"
    }

    private var controls: some View {
        HStack {
            Button {
                store.setListening(!store.isListening)
            } label: {
                Image(systemName: store.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.tool(isOn: store.isListening, size: 40))
            .accessibilityLabel(store.isListening ? "Mute camera" : "Listen to camera")
            .disabled(store.source != .iPhone)
            .opacity(store.source == .iPhone ? 1 : 0.4)

            Spacer()

            TalkHoldButton(isTalking: store.isTalking, otherTalker: store.status?.otherTalker) { on in
                store.setTalking(on)
            }
            .disabled(store.source != .iPhone)
            .opacity(store.source == .iPhone ? 1 : 0.4)
        }
        .padding(.bottom, Space.xs)
    }
}

/// Hold to talk, like a walkie-talkie: the mic is only open while the finger is down.
private struct TalkHoldButton: View {
    let isTalking: Bool
    let otherTalker: String?
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle().fill(isTalking ? Palette.accent : Palette.textPrimary)
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isTalking ? Palette.onAccent : .black)
        }
        .frame(width: 52, height: 52)
        .overlay(Circle().strokeBorder(Palette.frame, lineWidth: 3).padding(3))
        .scaleEffect(pressed ? 0.92 : 1)
        .animation(Motion.snappy, value: pressed)
        // A long press that never "completes" reports press and release, and wins over the
        // vertical page swipe (a zero-distance drag doesn't inside the camera pager).
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
            watchDebugLog("MM watch: talk button pressing=%d", pressing ? 1 : 0)
            guard pressing != pressed else { return }
            pressed = pressing
            onChange(pressing)
        })
        .sensoryFeedback(.start, trigger: isTalking)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(isTalking ? "Talking" : (otherTalker.map { "\($0) is talking" } ?? ""))
    }
}
