import Foundation

enum StreamQuality: String, CaseIterable {
    case quality = "Quality Mode"
    case performance = "Performance Mode"
    
    var resolution: (width: Int, height: Int) {
        switch self {
        case .quality:
            return (1920, 1080)  // 1080p
        case .performance:
            return (1280, 720)   // 720p
        }
    }
    
    var frameRate: Int {
        return 60  // Both modes use 60fps
    }
    
    var compressionQuality: CGFloat {
        switch self {
        case .quality:
            return 0.7
        case .performance:
            return 0.3
        }
    }
    
    var imageScale: CGFloat {
        switch self {
        case .quality:
            return 1.0
        case .performance:
            return 0.8
        }
    }
} 