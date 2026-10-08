import SwiftUI
import MirrorUI

/// "End-to-end encrypted", explained. Every claim here describes what the code does: if the
/// implementation changes, this sheet changes with it.
struct EncryptionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let points: [Point] = [
        Point(symbol: "arrow.left.arrow.right",
              title: "Video goes straight between your devices",
              detail: "Live video, sound and talk-back travel peer to peer over WebRTC, encrypted with keys made fresh for every connection. If a network blocks direct connections, an optional relay you set up only passes along packets it can't read."),
        Point(symbol: "key.fill",
              title: "The pairing code is the key",
              detail: "Pairing hands your device a 256-bit secret from the camera. Everything that sets up a connection, including the fingerprints that lock the video encryption to your two devices, is sealed with AES-GCM using that secret, so no one in between can step in."),
        Point(symbol: "number",
              title: "Codes never cross the network",
              detail: "When you add a nearby camera, the one-time code on its screen isn't sent anywhere. It unlocks a fresh key exchange, so someone else on your Wi-Fi can't intercept the pairing, and a wrong guess ends the attempt."),
        Point(symbol: "icloud",
              title: "iCloud only carries sealed envelopes",
              detail: "Away from home, connection setup and alerts pass through iCloud as sealed messages in mailboxes named by one-way hashes. Apple can see that a message exists, not what it says or which camera it's for. Alerts are opened on your device."),
        Point(symbol: "internaldrive",
              title: "Recordings stay on the camera",
              detail: "Footage is recorded and stored only on the camera device. Playback and clip exports stream to you over the same encrypted connection. No cloud video, ever."),
        Point(symbol: "person.badge.shield.checkmark",
              title: "You decide who watches",
              detail: "The camera shows who's watching. Disconnect or block any device, or reset the pairing code to lock everyone out. Removing a camera here tells it to forget this device."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Privacy", leadingAction: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    hero
                    VStack(spacing: Space.s) {
                        ForEach(points) { point in row(point) }
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
        }
        .canvasBackground()
    }

    private var hero: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "lock.fill")
                .font(.system(size: ControlSize.tool, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: ControlSize.shutter, height: ControlSize.shutter)
                .focusBrackets(Palette.accent, length: Space.l)
                .padding(.top, Space.l)
                .accessibilityHidden(true)
            Text("End-to-end encrypted").type(.title).multilineTextAlignment(.center)
            Text("Only your devices can see and hear your cameras. Not us, not Apple, not your network.")
                .type(.callout, color: Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ point: Point) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: point.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: Space.xl)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(point.title).type(.headline)
                Text(point.detail)
                    .type(.callout, color: Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .panel()
        .accessibilityElement(children: .combine)
    }
}
