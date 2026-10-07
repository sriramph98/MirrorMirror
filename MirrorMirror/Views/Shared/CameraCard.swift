import SwiftUI
import MirrorUI

// MARK: - Connection state

/// What a camera's connection LED says: LIVE (someone is watching), ON NETWORK, ONLINE, OFFLINE.
struct CameraLinkState: Equatable {
    enum Kind: Equatable { case live, onNetwork, online, offline }

    let kind: Kind
    /// When the camera last reported in, if known.
    let lastSeen: Date?

    @MainActor init(reachability: ViewerHub.Reachability, presence: PresenceInfo?, connection: CameraConnection) {
        let watching = connection.phase == .connected || (connection.status?.viewerCount ?? 0) > 0
            || (presence?.viewerCount ?? 0) > 0
        switch reachability {
        case .localNetwork:
            kind = watching ? .live : .onNetwork
            lastSeen = Date()
        case let .online(date):
            kind = watching ? .live : .online
            lastSeen = date
        case let .offline(date):
            kind = connection.phase == .connected ? .live : .offline
            lastSeen = date
        case .unknown:
            kind = connection.phase == .connected ? .live : .offline
            lastSeen = nil
        }
    }

    var label: String {
        switch kind {
        case .live: "Live"
        case .onNetwork: "On network"
        case .online: "Online"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch kind {
        case .live: Palette.live
        case .onNetwork, .online: Palette.ok
        case .offline: Palette.textTertiary
        }
    }

    var led: LED { LED(color, label: label, pulsing: kind == .live) }
}

/// Battery as the viewer knows it: from the live connection when there is one, else from presence.
struct CameraPower: Equatable {
    let level: Double?
    let charging: Bool
    let recording: Bool

    @MainActor init(presence: PresenceInfo?, connection: CameraConnection) {
        if let status = connection.status {
            level = status.batteryLevel
            charging = status.isCharging
            recording = status.isRecording
        } else {
            level = presence?.batteryLevel
            charging = presence?.isCharging ?? false
            recording = presence?.isRecording ?? false
        }
    }

    var known: Bool { level != nil || charging }
    var percentText: String { level.map { "\(Int(($0 * 100).rounded()))%" } ?? "--" }
    var symbol: String { batterySymbol(level, charging: charging) }

    var tint: Color {
        if charging { return Palette.ok }
        guard let level else { return Palette.textTertiary }
        return level < 0.2 ? Palette.live : level < 0.4 ? Palette.warn : Palette.ok
    }
}

extension EventKind {
    /// LED colour for an event kind: what was seen, what was heard, what is urgent, device health.
    var ledColor: Color {
        switch self {
        case .motion, .person, .animal: Palette.info
        case .sound, .barking: Palette.night
        case .crying, .glassBreak, .alarm: Palette.live
        case .lowBattery, .overheating: Palette.warn
        }
    }
}

extension Date {
    /// "2 MIN AGO" style, for readouts.
    var shortAgo: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "Now" }
        return formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

// MARK: - Camera card

/// Instrument card for a paired camera: name, connection LED, stat chips and a battery dial.
/// The whole card is the tap target.
struct CameraCard: View {
    let camera: PairedCamera
    @ObservedObject var connection: CameraConnection
    let reachability: ViewerHub.Reachability
    let presence: PresenceInfo?

    var body: some View {
        let link = CameraLinkState(reachability: reachability, presence: presence, connection: connection)
        let power = CameraPower(presence: presence, connection: connection)
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                link.led
                HStack(spacing: Space.s) {
                    Text(camera.name)
                        .type(.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !camera.notificationsEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityLabel("Alerts muted")
                    }
                }
                FlowLayout(spacing: Space.s) {
                    if power.known {
                        StatChip(power.percentText, symbol: power.symbol, tint: power.tint)
                    }
                    if power.recording {
                        StatChip("Rec", symbol: "record.circle", tint: Palette.live)
                    }
                    if case .localNetwork = reachability {
                        StatChip("Wi-Fi", symbol: "wifi", tint: Palette.textSecondary)
                    } else if let seen = link.lastSeen, link.kind != .live {
                        StatChip(seen.shortAgo, tag: "Seen")
                    }
                    if camera.source == .iCloud {
                        StatChip("iCloud", symbol: "icloud.fill", tint: Palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InstrumentGauge(value: power.level ?? 0, label: "Batt", valueText: power.percentText,
                            tint: power.known ? Palette.live : Palette.textTertiary)
                .frame(width: ControlSize.shutter + Space.l)
                .opacity(power.known ? 1 : 0.5)
        }
        .panel()
        .contentShape(.continuous(Radius.panel))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the live view")
    }
}

// MARK: - Flow layout

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Sheet chrome

extension View {
    /// Sheet presentation in the MirrorMirror style: canvas background, deck corner radius.
    func mirrorSheet() -> some View {
        self
            .presentationBackground(Palette.canvas)
            .presentationCornerRadius(Radius.deck)
            .preferredColorScheme(.dark)
    }
}
