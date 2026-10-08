import SwiftUI
import MirrorUI

/// Apple TV's side of "add by code": cameras on this network (each pairs with the one-time code
/// it shows) and the code from a camera's Pair screen, which works from anywhere.
struct TVNearbySection: View {
    @ObservedObject var adder: CameraAdder
    @ObservedObject var browser: NearbyCameraBrowser
    @EnvironmentObject private var hub: ViewerHub

    init(adder: CameraAdder) {
        self.adder = adder
        self.browser = adder.nearby
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Nearby cameras").tv(.caps)
            if adder.nearbyCameras.isEmpty {
                HStack(spacing: Space.m) {
                    ProgressView()
                    Text("Looking on this Wi-Fi…").tv(.callout, color: Palette.textSecondary)
                }
            }
            ForEach(adder.nearbyCameras) { camera in
                Button { adder.pick(camera) } label: {
                    HStack(spacing: Space.l) {
                        Image(systemName: "video.fill").foregroundStyle(Palette.accent)
                        Text(camera.name).tv(.headline).lineLimit(1)
                        Spacer(minLength: Space.m)
                        if adder.stage == .reaching(cameraID: camera.id) {
                            ProgressView()
                        } else if hub.cameras.contains(where: { $0.id == camera.id }) {
                            TVBadge("ADDED")
                        }
                    }
                }
                .buttonStyle(.tvRow())
                .disabled(adder.stage != .idle)
                .accessibilityHint("Shows a code on the camera to type here")
            }
            Button { adder.enterCameraCode() } label: { Label("Enter a camera's code", systemImage: "number") }
                .buttonStyle(.tvPill())
                .labelStyle(TVBarLabelStyle())
            if let error = adder.error {
                Text(error).tv(.footnote, color: Palette.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Typing a code on the TV: the system keyboard opens when the field is selected.
struct TVCodeEntry: View {
    @ObservedObject var adder: CameraAdder
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let numeric: Bool = {
            if case .nearbyCode = adder.stage { return true }
            return adder.stage == .checking
        }()
        let busy = adder.stage == .checking || adder.stage == .lookingUp
        VStack(spacing: Space.xxl) {
            VStack(spacing: Space.m) {
                Text(title).tv(.display).multilineTextAlignment(.center)
                Text(numeric ? "It's on the camera's screen now. It works once and never leaves your devices."
                             : "It's under the QR code on the camera's Pair screen and works from anywhere while that screen is open.")
                    .tv(.callout, color: Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            TextField(numeric ? "000 000" : "ABCD-2345", text: $adder.typed)
                .font(.custom(Fonts.monoBold, fixedSize: 64))
                .multilineTextAlignment(.center)
                .keyboardType(numeric ? .numberPad : .asciiCapable)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .frame(width: 720)
                .disabled(busy)
                .onSubmit { adder.submit() }
                .task(id: adder.typed) { if numeric, adder.canSubmit { adder.submit() } }
            if let error = adder.error {
                Text(error).tv(.footnote, color: Palette.warn)
            }
            HStack(spacing: Space.xl) {
                Button { adder.submit() } label: { Label(busy ? "Checking…" : "Add camera", systemImage: "checkmark") }
                    .buttonStyle(.tvPill(isOn: adder.canSubmit))
                    .labelStyle(TVBarLabelStyle())
                    .disabled(busy || !adder.canSubmit)
                Button { adder.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.tvPill())
                    .labelStyle(TVBarLabelStyle())
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity)
        .panel(padding: nil)
        .onAppear { fieldFocused = true }
    }

    private var title: String {
        if case let .nearbyCode(name) = adder.stage { return "Type the code on \(name)" }
        if adder.stage == .checking { return "Checking the code…" }
        return "Type the camera's code"
    }
}
