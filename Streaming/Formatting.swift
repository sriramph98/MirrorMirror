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

/// The line under the timeline strip while watching live: how much footage the selected
/// window holds, and what the viewer can do about it.
enum FootageSummary {
    static func windowLabel(_ window: TimeInterval) -> String {
        window >= 7 * 24 * 3600 ? "7D" : "\(Int(window / 3600))H"
    }

    static func describe(segments: [RecordingSegment], window: TimeInterval, isRecording: Bool,
                         now: Date = Date()) -> (title: String, caption: String) {
        let cutoff = now.addingTimeInterval(-window)
        let seconds = segments.filter { $0.end > cutoff }.reduce(0.0) { total, segment in
            total + segment.end.timeIntervalSince(max(segment.start, cutoff))
        }
        if seconds > 0 {
            let minutes = Int(seconds / 60)
            let text = minutes >= 60 ? "\(minutes / 60) H \(minutes % 60) M" : minutes > 0 ? "\(minutes) M" : "\(Int(seconds)) S"
            return ("\(text) recorded", "Drag the strip to rewind")
        }
        // Nothing inside the window. A clip only lands on the strip once its segment closes.
        let title = isRecording ? "Recording" : "No footage"
        if segments.isEmpty {
            return (title, isRecording ? "The first clip appears in about a minute" : "Nothing recorded yet")
        }
        return (title, "Older clips: pick a longer window")
    }
}
