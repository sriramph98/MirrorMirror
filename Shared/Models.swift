import Foundation
import CoreGraphics

// Types shared by the camera and viewer sides. Everything here is Codable because
// it travels over the WebRTC data channel as JSON.

// MARK: - Events

enum EventKind: String, Codable, CaseIterable, Hashable {
    case motion
    case person
    case animal
    case sound
    case crying
    case barking
    case glassBreak
    case alarm
    case lowBattery
    case overheating

    var title: String {
        switch self {
        case .motion: "Motion"
        case .person: "Person"
        case .animal: "Pet"
        case .sound: "Loud sound"
        case .crying: "Baby crying"
        case .barking: "Dog barking"
        case .glassBreak: "Glass breaking"
        case .alarm: "Alarm"
        case .lowBattery: "Low battery"
        case .overheating: "Overheating"
        }
    }

    var symbol: String {
        switch self {
        case .motion: "figure.walk.motion"
        case .person: "person.fill"
        case .animal: "pawprint.fill"
        case .sound: "waveform"
        case .crying: "figure.and.child.holdinghands"
        case .barking: "dog.fill"
        case .glassBreak: "wineglass"
        case .alarm: "light.beacon.max.fill"
        case .lowBattery: "battery.25percent"
        case .overheating: "thermometer.high"
        }
    }

    /// Sound kinds the user can toggle individually in camera settings.
    static let soundKinds: [EventKind] = [.crying, .barking, .glassBreak, .alarm, .sound]
}

struct CameraEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var kind: EventKind
    var label: String
    var confidence: Double
    /// File name of a small JPEG snapshot inside the recordings directory, if any.
    var thumbnailFile: String?
}

// MARK: - Recording

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case continuous
    case events
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous: "Continuous"
        case .events: "Motion & sound only"
        case .manual: "Manual"
        }
    }

    var detail: String {
        switch self {
        case .continuous: "Always records. The oldest footage is deleted when the storage cap is reached."
        case .events: "Keeps footage around motion and sound events, including a few seconds before each one."
        case .manual: "Records only when you press record, here or from a viewer."
        }
    }
}

struct RecordingSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Date
    var duration: TimeInterval
    var fileName: String
    var byteSize: Int64
    var width: Int
    var height: Int

    var end: Date { start.addingTimeInterval(duration) }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Back-to-back segments merged into continuous spans (gaps under `gap` seconds are
    /// bridged). Viewers only draw coverage, so this is what crosses the network: a week of
    /// continuous one-minute segments becomes a single entry instead of ten thousand.
    static func spans(_ segments: [RecordingSegment], bridging gap: TimeInterval = 2) -> [RecordingSegment] {
        var spans: [RecordingSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = spans.last, segment.start.timeIntervalSince(last.end) < gap {
                last.duration = max(last.duration, segment.end.timeIntervalSince(last.start))
                last.byteSize += segment.byteSize
                spans[spans.count - 1] = last
            } else {
                spans.append(RecordingSegment(id: segment.id, start: segment.start, duration: segment.duration, fileName: "",
                                              byteSize: segment.byteSize, width: segment.width, height: segment.height))
            }
        }
        return spans
    }
}

// MARK: - Quality

/// Export size for clips a viewer asks the camera to cut.
enum ExportQuality: String, Codable, CaseIterable {
    case original
    case hd720
    case sd540
}


enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case saver
    case standard
    case high
    case smooth
    case max2K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saver: "Data saver"
        case .standard: "Standard"
        case .high: "HD"
        case .smooth: "HD 60"
        case .max2K: "2K"
        }
    }

    var detail: String {
        switch self {
        case .saver: "540p · 24 fps"
        case .standard: "720p · 30 fps"
        case .high: "1080p · 30 fps"
        case .smooth: "1080p · 60 fps"
        case .max2K: "1440p · 30 fps"
        }
    }

    /// Long edge × short edge of the frames sent to viewers.
    var dimensions: (long: Int, short: Int) {
        switch self {
        case .saver: (960, 540)
        case .standard: (1280, 720)
        case .high, .smooth: (1920, 1080)
        case .max2K: (2560, 1440)
        }
    }

    var fps: Int {
        switch self {
        case .saver: 24
        case .smooth: 60
        default: 30
        }
    }

    var maxBitrate: Int {
        switch self {
        case .saver: 800_000
        case .standard: 2_000_000
        case .high: 4_000_000
        case .smooth: 6_000_000
        case .max2K: 8_000_000
        }
    }

    /// The next preset down, used when the camera device heats up.
    var lower: QualityPreset {
        switch self {
        case .saver, .standard: .saver
        case .high: .standard
        case .smooth, .max2K: .high
        }
    }
}

// MARK: - Camera settings

enum NightMode: String, Codable, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MainsFrequency: String, Codable, CaseIterable, Identifiable {
    case auto, hz50, hz60
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        }
    }

    /// Frequency to tune against. Auto picks from the region: most of the Americas use 60 Hz.
    var resolvedHz: Int {
        switch self {
        case .hz50: return 50
        case .hz60: return 60
        case .auto:
            let sixty: Set<String> = ["US", "CA", "MX", "BR", "CO", "VE", "PE", "EC", "TW", "KR", "PH", "SA", "CR", "PA", "GT", "HN", "SV", "NI", "DO", "PR", "CU", "JP"]
            return sixty.contains(Locale.current.region?.identifier ?? "") ? 60 : 50
        }
    }
}

struct CameraSettings: Codable, Equatable {
    var name: String = ""
    var quality: QualityPreset = .high
    var adaptToHeat: Bool = true

    var recordingMode: RecordingMode = .continuous
    var storageCapGB: Double = 10
    var recordAudio: Bool = true

    var motionEnabled: Bool = true
    var motionSensitivity: Double = 0.5
    var detectPeopleAndPets: Bool = true
    var soundEnabled: Bool = true
    var soundSensitivity: Double = 0.5
    var soundKinds: Set<EventKind> = Set(EventKind.soundKinds)
    var notifyViewers: Bool = true

    var nightMode: NightMode = .auto
    var nightEnhance: Bool = true
    var mainsFrequency: MainsFrequency = .auto

    var autoDimAfter: TimeInterval = 30
    var speakerVolume: Double = 1.0
}

// MARK: - Live camera status (camera → viewer, every couple of seconds)

struct LensOption: Codable, Hashable, Identifiable {
    /// Zoom factor as shown to the user (0.5, 1, 2, 3, 5).
    var factor: Double
    var id: Double { factor }
    var label: String {
        factor == floor(factor) ? "\(Int(factor))×" : String(format: "%.1g×", factor)
    }
}

struct CameraStatus: Codable, Equatable {
    var name: String
    var batteryLevel: Double?          // 0...1, nil when unknown
    var isCharging: Bool
    var thermal: Int                   // ProcessInfo.ThermalState.rawValue
    var isRecording: Bool
    var recordingMode: RecordingMode
    var storageUsedBytes: Int64
    var viewerCount: Int
    var quality: QualityPreset
    var effectiveQuality: QualityPreset
    var nightMode: NightMode
    var nightActive: Bool
    var torchOn: Bool
    var torchAvailable: Bool
    var usingFrontCamera: Bool
    var lenses: [LensOption]
    var zoom: Double
    var maxZoom: Double
    var motionLevel: Double
    var soundLevel: Double             // 0...1
    var settings: CameraSettings
}
