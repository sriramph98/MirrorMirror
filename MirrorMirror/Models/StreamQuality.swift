import Foundation

enum StreamQuality: String, CaseIterable {
    case performance = "Performance (720p)"
    case balanced = "Balanced (1080p)"
    case quality = "Quality (4K)"
    
    var resolution: (width: Int, height: Int) {
        switch self {
        case .performance:
            return (1280, 720)  // 720p
        case .balanced:
            return (1920, 1080)  // 1080p
        case .quality:
            return (3840, 2160)  // 4K
        }
    }
    
    var frameRate: Int {
        switch self {
        case .performance:
            return 60
        case .balanced:
            return 60
        case .quality:
            return 30
        }
    }
    
    var compressionQuality: Float {
        switch self {
        case .performance:
            return 0.7
        case .balanced:
            return 0.8
        case .quality:
            return 0.9
        }
    }
    
    var maxDataSize: Int {
        switch self {
        case .performance:
            return 200_000  // 200KB
        case .balanced:
            return 500_000  // 500KB
        case .quality:
            return 1_000_000  // 1MB
        }
    }
} 