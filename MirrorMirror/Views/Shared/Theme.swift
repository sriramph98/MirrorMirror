import SwiftUI

enum Theme {
    static let accent = Color(hex: "EEED7C")
    static let card = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let stroke = Color.white.opacity(0.14)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

/// The app's gradient card look, carried over from the original home screen.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                EllipticalGradient(stops: [
                    .init(color: Color(red: 0.11, green: 0.11, blue: 0.11), location: 0),
                    .init(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1),
                ], center: UnitPoint(x: 0.48, y: -0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).inset(by: 0.75).stroke(Theme.stroke, lineWidth: 1.5))
    }
}

extension View {
    func card(cornerRadius: CGFloat = 16) -> some View { modifier(CardBackground(cornerRadius: cornerRadius)) }
}

/// Round translucent control used over live video.
struct OverlayButton: View {
    let systemName: String
    var isOn = false
    var tint: Color = .white
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(isOn ? .black : tint)
                .frame(width: size, height: size)
                .background(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .green
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption.weight(.semibold)).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Toast shown at the bottom of video screens.
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Too hot"
        @unknown default: "Unknown"
        }
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

func batterySymbol(_ level: Double?, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    guard let level else { return "battery.0percent" }
    switch level {
    case ..<0.13: return "battery.0percent"
    case ..<0.38: return "battery.25percent"
    case ..<0.63: return "battery.50percent"
    case ..<0.88: return "battery.75percent"
    default: return "battery.100percent"
    }
}
