import SwiftUI
import MirrorUI

/// Getting cameras onto this Apple TV. Same-Apple-Account devices arrive on their own through
/// iCloud; anyone else types the code shown here into MirrorMirror on their iPhone, iPad or Mac
/// and the camera list travels sealed through iCloud. Menu returns to the wall.
struct PairView: View {
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Item?

    @State private var code = DevicePairing.makeCode()
    @State private var expires = Date().addingTimeInterval(DevicePairing.codeLifetime)
    @State private var receiveTask: Task<Void, Never>?
    @State private var waiting = false
    @State private var failed = false
    @State private var added: [PairedCamera]?
    @State private var cameraCountAtOpen = 0
    @StateObject private var adder = CameraAdder()

    /// Typing a nearby camera's code, or a camera code from its Pair screen.
    private var isTypingCode: Bool {
        switch adder.stage {
        case .nearbyCode, .checking, .cameraCode, .lookingUp: true
        default: false
        }
    }

    enum Item: Hashable { case newCode, back, done }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack(alignment: .center) {
                Wordmark(size: 30)
                Spacer()
                Text("Pair a device").tv(.navTitle)
            }
            Spacer(minLength: 0)
            if let added {
                confirmation(added).frame(maxWidth: .infinity)
            } else if isTypingCode {
                TVCodeEntry(adder: adder)
            } else {
                HStack(alignment: .top, spacing: TVSize.gutter) {
                    codePanel
                    sidePanel
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TVSize.margin)
        .padding(.vertical, Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(Palette.frame)
        .onExitCommand { router.screen = .wall }
        .onAppear {
            cameraCountAtOpen = hub.cameras.count
            adder.onInvite = { invite in
                let camera = hub.add(invite)
                cameraCountAtOpen = hub.cameras.count
                added = [camera]
            }
            adder.start()
            startReceiving()
            focus = .newCode
        }
        .onDisappear {
            receiveTask?.cancel()
            adder.stop()
        }
        #if DEBUG
        // Simulator testing without a remote: "nearby/0", "type/123456", "cameracode".
        .onChange(of: router.debugCommand) { _, command in handleDebug(command) }
        #endif
        .onChange(of: hub.cameras.count) { _, count in
            // Cameras that arrived through iCloud while this screen is up count as paired too.
            if added == nil, count > cameraCountAtOpen {
                added = Array(hub.cameras.suffix(count - cameraCountAtOpen))
            }
        }
        .onChange(of: added?.count) { _, _ in if added != nil { focus = .done } }
        .animation(reduceMotion ? nil : Motion.smooth, value: added?.count)
        .animation(reduceMotion ? nil : Motion.fade, value: failed)
    }

    // MARK: Code

    private var codePanel: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your code").tv(.caps)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, expires.timeIntervalSince(context.date))
                    TVReadoutLine([remaining > 0 ? String(format: "%d:%02d left", Int(remaining) / 60, Int(remaining) % 60) : "Expired"],
                                  color: remaining < 60 ? Palette.warn : Palette.textSecondary)
                }
            }

            Text(DevicePairing.formatted(code))
                .font(.custom(Fonts.groteskBold, fixedSize: 150))
                .tracking(14)
                .monospacedDigit()
                .foregroundStyle(failed ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xl)
                .padding(.horizontal, Space.l)
                .focusBrackets(Palette.textTertiary, length: Space.xxxl, lineWidth: 3, inset: 0)
                .accessibilityLabel("Pairing code")
                .accessibilityValue(code.map(String.init).joined(separator: " "))

            Text("On your iPhone, iPad or Mac open Mira › Settings › Pair Apple TV or Vision Pro and enter this code.")
                .tv(.body, color: Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.xl) {
                if failed {
                    TVLED(Palette.warn, label: hub.cloudAvailable ? "Code expired" : "iCloud not signed in")
                } else if waiting {
                    TVLED(Palette.accent, label: "Waiting for a device", pulsing: true)
                }
                Spacer(minLength: Space.l)
                Button { newCode() } label: { Label("New code", systemImage: "arrow.clockwise") }
                    .buttonStyle(.tvPill(isOn: failed))
                    .labelStyle(TVBarLabelStyle())
                    .focused($focus, equals: .newCode)
                Button { router.screen = .wall } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.tvPill())
                    .labelStyle(TVBarLabelStyle())
                    .focused($focus, equals: .back)
                    .accessibilityLabel("Back to the wall")
            }
            if failed {
                Text(hub.cloudAvailable
                     ? "No device entered the code before it expired. Make a new code and try again."
                     : "This Apple TV isn't signed in to iCloud, so a code can't be verified end-to-end. Sign in under Settings › Users and Accounts, then make a new code.")
                    .tv(.footnote, color: Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.xxl)
        .frame(width: 1080)
        .panel(padding: nil)
        .focusSection()
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            TVNearbySection(adder: adder)
            Divider().overlay(Palette.hairline)
            Text("Same Apple Account").tv(.caps)
            HStack(spacing: Space.l) {
                Image(systemName: "icloud.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(Palette.info)
                TVLED(hub.cloudAvailable ? Palette.ok : Palette.textTertiary, label: hub.cloudAvailable ? "Signed in" : "Not signed in")
            }
            Text("Any iPhone or iPad on this Apple Account that runs Mira as a camera appears on the wall on its own. Nothing to type.")
                .tv(.callout, color: Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .frame(width: 640)
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(padding: nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Done

    private func confirmation(_ cameras: [PairedCamera]) -> some View {
        TVEmptyState(symbol: "checkmark.viewfinder",
                     title: cameras.count == 1 ? cameras[0].name : "\(cameras.count) cameras added",
                     message: cameras.count == 1 ? "Ready to watch." : cameras.map(\.name).joined(separator: ", ")) {
            HStack(spacing: Space.xl) {
                Button { router.screen = .wall } label: { Label("Show the wall", systemImage: "square.grid.2x2.fill") }
                    .buttonStyle(.tvPill(isOn: true))
                    .labelStyle(TVBarLabelStyle())
                    .focused($focus, equals: .done)
                Button { added = nil; newCode() } label: { Label("Pair more", systemImage: "plus") }
                    .buttonStyle(.tvPill())
                    .labelStyle(TVBarLabelStyle())
            }
        }
        .transition(.opacity)
    }

    #if DEBUG
    private func handleDebug(_ command: String?) {
        guard let parts = command?.split(separator: "/").map(String.init), let verb = parts.first else { return }
        switch verb {
        case "nearby":
            if parts.count > 1, let index = Int(parts[1]), adder.nearbyCameras.indices.contains(index) {
                adder.pick(adder.nearbyCameras[index])
            }
        case "type": adder.typed = parts.count > 1 ? parts[1] : ""
        case "cameracode": adder.enterCameraCode()
        default: break
        }
    }
    #endif

    // MARK: Receiving

    private func newCode() {
        code = DevicePairing.makeCode()
        expires = Date().addingTimeInterval(DevicePairing.codeLifetime)
        startReceiving()
    }

    private func startReceiving() {
        receiveTask?.cancel()
        failed = false
        waiting = true
        let current = code
        receiveTask = Task {
            let payload = await DevicePairing.receive(code: current)
            guard !Task.isCancelled, current == code else { return }
            waiting = false
            if let payload {
                let cameras = payload.cameras.map { hub.add(PairingInvite(key: $0.key, name: $0.name)) }
                cameraCountAtOpen = hub.cameras.count
                added = cameras
            } else {
                failed = true
            }
        }
    }
}
