import Foundation
import CoreGraphics
import UIKit

enum StreamQuality: String, Codable, CaseIterable {
    case performance = "Performance"
    case balanced = "Balanced"
    case quality = "Quality"
    
    var resolution: CGSize {
        switch self {
        case .performance:
            return CGSize(width: 1280, height: 720)  // 720p
        case .balanced:
            return CGSize(width: 1920, height: 1080) // 1080p
        case .quality:
            return CGSize(width: 3840, height: 2160) // 4K
        }
    }
    
    var fps: Int {
        switch self {
        case .performance, .balanced:
            return 60
        case .quality:
            return 30
        }
    }
    
    var description: String {
        switch self {
        case .performance:
            return "Performance (720p • 60 FPS)"
        case .balanced:
            return "Balanced (1080p • 60 FPS)"
        case .quality:
            return "Quality (4K • 30 FPS)"
        }
    }
} 