import Foundation
import CoreGraphics  // Add for CGFloat

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
    
    var compressionQuality: CGFloat {
        switch self {
        case .performance:
            return 0.95  // Higher quality for performance mode
        case .balanced:
            return 0.98  // Very high quality for balanced mode
        case .quality:
            return 1.0   // Lossless for quality mode
        }
    }
    
    var maxDataSize: Int {
        switch self {
        case .performance:
            return 2_000_000    // 2MB for 720p
        case .balanced:
            return 5_000_000    // 5MB for 1080p
        case .quality:
            return 15_000_000   // 15MB for 4K
        }
    }
} 