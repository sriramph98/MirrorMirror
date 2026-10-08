import SwiftUI
import MirrorUI

/// Vision Pro's "Nearby & code" path: cameras on this network (each pairs with the one-time code
/// it shows), or the code from a camera's Pair screen, which works from anywhere.
struct VisionAddByCode: View {
    @ObservedObject var adder: CameraAdder
    @EnvironmentObject private var hub: ViewerHub

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            switch adder.stage {
            case let .nearbyCode(name):
                entry(title: "Type the code on \(name)",
                      detail: "It's on the camera's screen now. It works once and never leaves your devices.",
                      placeholder: "000 000", numeric: true)
            case .checking:
                entry(title: "Checking the code…", detail: "", placeholder: "000 000", numeric: true)
            case .cameraCode, .lookingUp:
                entry(title: "Type the camera's code",
                      detail: "It's under the QR code on the camera's Pair screen and works from anywhere while that screen is open.",
                      placeholder: "ABCD-2345", numeric: false)
            case .idle, .reaching:
                VisionNearbyList(browser: adder.nearby, adder: adder)
                Button { adder.enterCameraCode() } label: { Label("Enter a camera's code", systemImage: "number") }
                    .buttonStyle(.secondary)
                    .pillHover()
            }
            if let error = adder.error {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.live)
                    Text(error).type(.footnote, color: Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.xs)
            }
        }
        .animation(Motion.smooth, value: adder.stage)
    }

    private func entry(title: String, detail: String, placeholder: String, numeric: Bool) -> some View {
        let busy = adder.stage == .checking || adder.stage == .lookingUp
        return VStack(spacing: Space.l) {
            VStack(spacing: Space.xs) {
                Text(title).type(.title).multilineTextAlignment(.center)
                if !detail.isEmpty {
                    Text(detail).type(.callout, color: Palette.textSecondary).multilineTextAlignment(.center)
                }
            }
            CodeField(placeholder, text: $adder.typed, numeric: numeric)
                .frame(maxWidth: ControlSize.readableWidth / 2)
                .disabled(busy)
                .onSubmit { adder.submit() }
                // Nearby codes go as soon as all six digits are in.
                .task(id: adder.typed) { if numeric, adder.canSubmit { adder.submit() } }
            HStack(spacing: Space.m) {
                Button("Cancel") { adder.cancel() }
                    .buttonStyle(.secondary)
                    .pillHover()
                Button(busy ? "Checking…" : "Add camera") { adder.submit() }
                    .buttonStyle(.primary)
                    .pillHover()
                    .disabled(busy || !adder.canSubmit)
                    .opacity(adder.canSubmit ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .panel()
    }
}

private struct VisionNearbyList: View {
    @ObservedObject var browser: NearbyCameraBrowser
    @ObservedObject var adder: CameraAdder
    @EnvironmentObject private var hub: ViewerHub

    var body: some View {
        SettingsSection("Nearby", symbol: "wifi",
                        footer: "Cameras in camera mode on this Wi-Fi. Pick one and it shows a code to type here.") {
            if adder.nearbyCameras.isEmpty {
                SettingRow("Looking for cameras…", symbol: "magnifyingglass") {
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(adder.nearbyCameras) { camera in
                Button { adder.pick(camera) } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: "video.fill").foregroundStyle(Palette.accent).frame(width: Space.xl)
                        Text(camera.name).type(.headline).lineLimit(1)
                        Spacer(minLength: Space.s)
                        if adder.stage == .reaching(cameraID: camera.id) {
                            ProgressView().controlSize(.small)
                        } else if hub.cameras.contains(where: { $0.id == camera.id }) {
                            Badge("ADDED")
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect()
                .disabled(adder.stage != .idle)
            }
        }
    }
}
