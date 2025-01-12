import MultipeerConnectivity
import Combine
import AVFoundation

class ConnectionManager: NSObject, ObservableObject {
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var selectedPeer: MCPeerID?
    @Published var receivedImage: UIImage?
    @Published var streamQuality: StreamQuality = .performance {
        didSet {
            if oldValue != streamQuality {
                print("Quality changed to: \(streamQuality.rawValue)")
                // Reset the frame time to allow immediate next frame
                lastFrameTime = 0
                // Notify quality change to peers
                if !connectedPeers.isEmpty {
                    let qualityData = ["quality": streamQuality.rawValue].description.data(using: .utf8)!
                    sendData(qualityData, to: connectedPeers)
                }
            }
        }
    }
    
    private let serviceType = "mirror-mirror"
    private let myPeerId: MCPeerID
    private var session: MCSession?
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?
    private var retryCount = 0
    private let maxRetries = 3
    private var lastFrameTime: TimeInterval = 0
    private var minFrameInterval: TimeInterval {
        return 1.0 / TimeInterval(streamQuality.frameRate)
    }
    
    enum ConnectionState {
        case connected
        case connecting
        case disconnected
        case failed
    }
    
    override init() {
        myPeerId = MCPeerID(displayName: UIDevice.current.name)
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        // Clean up existing session if any
        session?.disconnect()
        session = nil
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceBrowser?.stopBrowsingForPeers()
        
        // Create new session
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        serviceAdvertiser?.delegate = self
        
        serviceBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        serviceBrowser?.delegate = self
    }
    
    func startAdvertising() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serviceAdvertiser?.startAdvertisingPeer()
        }
    }
    
    func stopAdvertising() {
        serviceAdvertiser?.stopAdvertisingPeer()
    }
    
    func startBrowsing() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serviceBrowser?.startBrowsingForPeers()
        }
    }
    
    func stopBrowsing() {
        serviceBrowser?.stopBrowsingForPeers()
    }
    
    func sendData(_ data: Data, to peers: [MCPeerID]) {
        guard let session = session else { return }
        do {
            // Use reliable for quality mode, unreliable for performance mode
            let dataMode: MCSessionSendDataMode = streamQuality == .quality ? .reliable : .unreliable
            try session.send(data, toPeers: peers, with: dataMode)
        } catch {
            print("Error sending data: \(error.localizedDescription)")
        }
    }
    
    func invitePeer(_ peer: MCPeerID) {
        guard connectionState != .connecting else { return }
        guard let session = session else {
            print("No valid session available")
            return
        }
        
        connectionState = .connecting
        retryCount = 0
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serviceBrowser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        }
    }
    
    private func resetConnection() {
        DispatchQueue.main.async { [weak self] in
            self?.connectedPeers.removeAll()
            self?.connectionState = .disconnected
            self?.setupSession()
            
            // Restart services
            self?.stopAdvertising()
            self?.stopBrowsing()
            self?.startAdvertising()
            self?.startBrowsing()
        }
    }
    
    func sendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastFrameTime >= minFrameInterval else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              connectionState == .connected,
              !connectedPeers.isEmpty else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        // Scale down the image based on quality mode
        let scale = CGAffineTransform(scaleX: streamQuality.imageScale, y: streamQuality.imageScale)
        let scaledImage = ciImage.transformed(by: scale)
        
        // Resize image to match quality mode resolution
        let targetSize = CGSize(width: streamQuality.resolution.width, height: streamQuality.resolution.height)
        let extent = scaledImage.extent
        let scaleX = targetSize.width / extent.width
        let scaleY = targetSize.height / extent.height
        let scaledCIImage = scaledImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        guard let cgImage = context.createCGImage(scaledCIImage, from: scaledCIImage.extent) else { return }
        
        let image = UIImage(cgImage: cgImage)
        guard let imageData = image.jpegData(compressionQuality: streamQuality.compressionQuality) else { return }
        
        // Only send if data size is reasonable (adjust based on quality mode)
        let maxSize = streamQuality == .quality ? 200_000 : 100_000
        guard imageData.count < maxSize else { return }
        
        sendData(imageData, to: connectedPeers)
        lastFrameTime = currentTime
    }
}

extension ConnectionManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.connectionState = .connected
                self.retryCount = 0
                
            case .connecting:
                self.connectionState = .connecting
                
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                
                if self.connectionState == .connecting && self.retryCount < self.maxRetries {
                    // Retry connection
                    self.retryCount += 1
                    guard let currentSession = self.session else { return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.serviceBrowser?.invitePeer(peerID, to: currentSession, withContext: nil, timeout: 30)
                    }
                } else {
                    self.connectionState = self.connectedPeers.isEmpty ? .disconnected : .connected
                    if self.connectedPeers.isEmpty {
                        self.resetConnection()
                    }
                }
                
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Try to parse quality change message
        if let message = String(data: data, encoding: .utf8),
           message.contains("quality") {
            if message.contains("Quality Mode") {
                DispatchQueue.main.async {
                    self.streamQuality = .quality
                }
            } else if message.contains("Performance Mode") {
                DispatchQueue.main.async {
                    self.streamQuality = .performance
                }
            }
            return
        }
        
        // Handle image data
        if let image = UIImage(data: data) {
            DispatchQueue.main.async {
                self.receivedImage = image
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension ConnectionManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            self.connectionState = .connecting
            invitationHandler(true, session)
        }
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Failed to start advertising: \(error.localizedDescription)")
        resetConnection()
    }
}

extension ConnectionManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async { [weak self] in
            if !(self?.availablePeers.contains(peerID) ?? false) {
                self?.availablePeers.append(peerID)
            }
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.availablePeers.removeAll { $0 == peerID }
            if self?.selectedPeer == peerID {
                self?.connectionState = .disconnected
            }
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Failed to start browsing: \(error.localizedDescription)")
        resetConnection()
    }
} 