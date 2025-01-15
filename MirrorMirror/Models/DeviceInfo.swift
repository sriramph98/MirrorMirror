import Foundation
import UIKit

struct DeviceInfo: Codable, Identifiable {
    let id: UUID
    let name: String
    let model: String
    let systemVersion: String
    
    init() {
        self.id = UUID()
        self.name = UIDevice.current.name
        self.model = UIDevice.current.model
        self.systemVersion = UIDevice.current.systemVersion
    }
} 