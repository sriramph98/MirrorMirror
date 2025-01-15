import Foundation
import MultipeerConnectivity
import SwiftUI
import AVFoundation
import UIKit

enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case failed
}

class ConnectionManager: NSObject, ObservableObject {
    private let serviceType = "mirror-mirror"
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private let myPeerId = MCPeerID(displayName: UIDevice.current.name)
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isStreamEnabled: Bool = false
    @Published var isRemoteStreamEnabled: Bool = false
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var selectedPeer: MCPeerID?
    @Published var streamQuality: StreamQuality = .balanced
    @Published var receivedImage: UIImage?
    
    override init() {
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self
    }
    
    func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }
    
    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
    }
    
    func startBrowsing() {
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }
    
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
    }
    
    func invitePeer(_ peer: MCPeerID) {
        guard let session = session else { return }
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        selectedPeer = peer
        connectionState = .connecting
    }
    
    func broadcast(deviceInfo: DeviceInfo) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        
        do {
            let data = try JSONEncoder().encode(deviceInfo)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("Error broadcasting device info: \(error)")
        }
    }
    
    func sendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isStreamEnabled, let session = session, !session.connectedPeers.isEmpty else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        // Scale the image based on quality settings
        let scale = streamQuality.resolution.width / CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else { return }
        
        do {
            try session.send(jpegData, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            print("Error sending video frame: \(error)")
        }
    }
    
    func capturePhoto(completion: @escaping (Bool) -> Void) {
        guard let image = receivedImage else {
            completion(false)
            return
        }
        
        // Save image to photos
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
        completion(true)
    }
    
    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            print("Error saving image: \(error.localizedDescription)")
        } else {
            print("Image saved successfully")
        }
    }
}

// MARK: - MCSessionDelegate
extension ConnectionManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.connectionState = .connected
            case .connecting:
                self.connectionState = .connecting
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                if self.connectedPeers.isEmpty {
                    self.connectionState = .disconnected
                    self.isRemoteStreamEnabled = false
                } else {
                    self.connectionState = .connected
                }
            @unknown default:
                self.connectionState = .failed
                self.isRemoteStreamEnabled = false
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            if let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.isRemoteStreamEnabled = true
                    self.receivedImage = image
                }
            } else {
                let deviceInfo = try JSONDecoder().decode(DeviceInfo.self, from: data)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .deviceInfoReceived,
                        object: nil,
                        userInfo: ["deviceInfo": deviceInfo]
                    )
                }
            }
        } catch {
            print("Error processing received data: \(error)")
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension ConnectionManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            self.connectionState = .connecting
            invitationHandler(true, self.session)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension ConnectionManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            if !self.availablePeers.contains(peerID) {
                self.availablePeers.append(peerID)
            }
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.availablePeers.removeAll { $0 == peerID }
        }
    }
}

extension Notification.Name {
    static let deviceInfoReceived = Notification.Name("deviceInfoReceived")
} 