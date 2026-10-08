import SwiftUI
import MirrorUI

/// Cameras (with Remove), pairing, and About. Menu returns to the wall.
struct SettingsView: View {
    @EnvironmentObject private var hub: ViewerHub
    @EnvironmentObject private var router: TVRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Item?
    /// Camera whose Remove has been pressed once; the second press removes it.
    @State private var confirming: String?
    @State private var confirmTask: Task<Void, Never>?

    enum Item: Hashable { case remove(String), pair, back }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack(alignment: .center) {
                Wordmark(size: 30)
                Spacer()
                Text("Settings").tv(.navTitle)
            }
            HStack(alignment: .top, spacing: TVSize.gutter * 1.5) {
                camerasPanel
                aboutPanel
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TVSize.margin)
        .padding(.vertical, Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground(Palette.frame)
        .onExitCommand { router.screen = .wall }
        .onAppear { focus = hub.cameras.first.map { .remove($0.id) } ?? .pair }
        .animation(reduceMotion ? nil : Motion.snappy, value: confirming)
        .animation(reduceMotion ? nil : Motion.smooth, value: hub.cameras)
    }

    // MARK: Cameras

    private var camerasPanel: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                Text("Cameras").tv(.caps)
                Text("\(hub.cameras.count)").tv(.readoutLarge, color: Palette.textPrimary)
                Spacer()
            }
            if hub.cameras.isEmpty {
                Text("No cameras yet. Pair this Apple TV with the device that has them.")
                    .tv(.callout, color: Palette.textSecondary)
                    .padding(.vertical, Space.l)
            } else {
                VStack(spacing: Space.s) {
                    ForEach(hub.cameras) { camera in
                        row(camera)
                    }
                }
            }
            HStack(spacing: Space.l) {
                Button { router.screen = .pair } label: { Label("Pair another device", systemImage: "plus") }
                    .buttonStyle(.tvPill(isOn: hub.cameras.isEmpty))
                    .focused($focus, equals: .pair)
                Button { router.screen = .wall } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.tvPill())
                    .focused($focus, equals: .back)
                    .accessibilityLabel("Back to the wall")
            }
            .labelStyle(TVBarLabelStyle())
            .padding(.top, Space.m)
        }
        .padding(Space.xxl)
        .frame(width: 1080, alignment: .leading)
        .panel(padding: nil)
        .focusSection()
    }

    private func row(_ camera: PairedCamera) -> some View {
        let reach = hub.reachability(of: camera)
        let isConfirming = confirming == camera.id
        return HStack(spacing: Space.xl) {
            TVLED(reach.color)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(camera.name).tv(.headline).lineLimit(1)
                TVReadoutLine([reach.label, camera.source == .iCloud ? "iCloud" : "Invite"], color: Palette.textTertiary)
            }
            Spacer(minLength: Space.l)
            Button {
                if isConfirming {
                    confirmTask?.cancel()
                    confirming = nil
                    hub.remove(camera)
                    if hub.audioFocus == camera.id { hub.audioFocus = hub.cameras.first?.id ?? "" }
                    focus = hub.cameras.first.map { .remove($0.id) } ?? .pair
                } else {
                    confirming = camera.id
                    confirmTask?.cancel()
                    confirmTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled, confirming == camera.id { confirming = nil }
                    }
                }
            } label: {
                Label(isConfirming ? "Press again to remove" : "Remove", systemImage: isConfirming ? "exclamationmark.triangle.fill" : "trash")
                    .labelStyle(TVBarLabelStyle())
            }
            .buttonStyle(.tvPill(tint: Palette.live))
            .focused($focus, equals: .remove(camera.id))
            .accessibilityLabel(isConfirming ? "Confirm removing \(camera.name)" : "Remove \(camera.name)")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
        .background(Palette.raised.opacity(0.5), in: .continuous(Radius.control))
    }

    // MARK: About

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("About").tv(.caps)
            Wordmark(size: 36)
            aboutRow("Version", value: Bundle.main.tvVersionReadout)
            aboutRow("This device", value: UIDevice.current.name)
            HStack(spacing: Space.l) {
                Text("iCloud").tv(.callout, color: Palette.textSecondary)
                Spacer()
                TVLED(hub.cloudAvailable ? Palette.ok : Palette.textTertiary, label: hub.cloudAvailable ? "Signed in" : "Not signed in")
            }
            Divider().overlay(Palette.hairline)
            Text("Cameras stream to this Apple TV directly over your network, or through iCloud when you're away. Nothing passes through anyone else's server. Sound follows the tile you focus on the wall.")
                .tv(.footnote, color: Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.xxl)
        .frame(width: 560, alignment: .leading)
        .panel(padding: nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            Text(label).tv(.callout, color: Palette.textSecondary)
            Spacer(minLength: Space.l)
            Text(value).tv(.readout, color: Palette.textPrimary).lineLimit(2).multilineTextAlignment(.trailing)
        }
    }
}
