import SwiftUI

// Formatting helpers shared by the screens. Visual tokens live in the MirrorUI package.

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
