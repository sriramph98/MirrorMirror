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
            } else {
                HStack(alignment: .top, spacing: TVSize.gutter * 1.5) {
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
            startReceiving()
            focus = .newCode
        }
        .onDisappear { receiveTask?.cancel() }
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

            Text("On your iPhone, iPad or Mac open MirrorMirror › Settings › Pair Apple TV or Vision Pro and enter this code.")
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
            Text("Same Apple Account").tv(.caps)
            HStack(spacing: Space.l) {
                Image(systemName: "icloud.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(Palette.info)
                TVLED(hub.cloudAvailable ? Palette.ok : Palette.textTertiary, label: hub.cloudAvailable ? "Signed in" : "Not signed in")
            }
            Text("Any iPhone or iPad on this Apple Account that runs MirrorMirror as a camera appears on the wall on its own. Nothing to type.")
                .tv(.callout, color: Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Palette.hairline)
            Text("Cameras here").tv(.caps)
            TVNumeral("\(hub.cameras.count)", unit: hub.cameras.count == 1 ? "camera" : "cameras")
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .frame(width: 560)
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
