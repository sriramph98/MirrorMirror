import Foundation
import CoreGraphics
import UIKit

enum StreamQuality: String, Codable, CaseIterable {
    case performance = "Performance"
    case quality = "Quality"
    
    var resolution: CGSize {
        switch self {
        case .performance:
            return CGSize(width: 1280, height: 720)  // 720p
        case .quality:
            return CGSize(width: 1920, height: 1080) // 1080p
        }
    }
    
    var fps: Int {
        return 60 // Both modes use 60 FPS
    }
    
    var description: String {
        switch self {
        case .performance:
            return "Performance (720p • 60 FPS)"
        case .quality:
            return "Quality (1080p • 60 FPS)"
        }
    }
} 