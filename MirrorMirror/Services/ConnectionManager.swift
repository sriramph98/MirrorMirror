import MultipeerConnectivity
import Combine
import AVFoundation

class ConnectionManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var usbDevices: [USBDevice] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var selectedPeer: MCPeerID?
    @Published var selectedUSBDevice: USBDevice?
    @Published var receivedImage: UIImage?
    @Published var isStreamEnabled: Bool = true {
        didSet {
            if oldValue != isStreamEnabled {
                // Notify stream state change to peers
                if !connectedPeers.isEmpty {
                    let streamMessage: [String: String] = [
                        "type": "stream_state",
                        "enabled": isStreamEnabled ? "true" : "false"
                    ]
                    if let streamData = try? JSONSerialization.data(withJSONObject: streamMessage) {
                        sendData(streamData, to: connectedPeers)
                    }
                }
                // Clear received image if stream is disabled
                if !isStreamEnabled {
                    receivedImage = nil
                }
            }
        }
    }
    @Published var isRemoteStreamEnabled: Bool = true
    @Published var streamQuality: StreamQuality = .performance {
        didSet {
            if oldValue != streamQuality {
                print("Quality changed to: \(streamQuality.rawValue)")
                // Reset the frame time to allow immediate next frame
                lastFrameTime = 0
                // Notify quality change to peers
                if !connectedPeers.isEmpty {
                    let qualityMessage: [String: String] = [
                        "type": "quality_change",
                        "mode": streamQuality.rawValue
                    ]
                    if let qualityData = try? JSONSerialization.data(withJSONObject: qualityMessage) {
                        sendData(qualityData, to: connectedPeers)
                    }
                }
            }
        }
    }
    @Published var connectionType: ConnectionType = .wireless
    
    private let serviceType = "mirror-mirror"
    private let myPeerId: MCPeerID
    private var session: MCSession?
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?
    private var usbConnectionObserver: NSObjectProtocol?
    private var retryCount = 0
    private let maxRetries = 3
    private var lastFrameTime: TimeInterval = 0
    private var minFrameInterval: TimeInterval {
        return 1.0 / TimeInterval(streamQuality.frameRate)
    }
    
    enum ConnectionType {
        case wireless
        case usb
    }
    
    enum ConnectionState {
        case connected
        case connecting
        case disconnected
        case failed
    }
    
    struct USBDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let type: String
        
        static func == (lhs: USBDevice, rhs: USBDevice) -> Bool {
            return lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
    
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var photoCaptureCompletion: ((Bool) -> Void)?
    
    override init() {
        myPeerId = MCPeerID(displayName: UIDevice.current.name)
        super.init()
        setupSession()
        setupUSBConnectionObserver()
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
    
    private func setupUSBConnectionObserver() {
        // Request camera access first
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                print("Camera access granted")
                // Start monitoring for device connections
                NotificationCenter.default.addObserver(
                    forName: .AVCaptureDeviceWasConnected,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    if let device = notification.object as? AVCaptureDevice {
                        self?.handleDeviceConnection(device)
                    }
                }
                
                NotificationCenter.default.addObserver(
                    forName: .AVCaptureDeviceWasDisconnected,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    if let device = notification.object as? AVCaptureDevice {
                        self?.removeUSBDevice(device)
                    }
                }
                
                // Initial scan for connected devices
                DispatchQueue.main.async { [weak self] in
                    self?.scanForUSBDevices()
                }
            } else {
                print("Camera access denied")
            }
        }
    }
    
    private func scanForUSBDevices() {
        print("Scanning for external devices...")
        
        // First check for Continuity Camera devices
        if #available(iOS 16.0, *) {
            print("Checking Continuity Camera availability...")
            let screenCaptureSession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.continuityCamera],
                mediaType: .video,
                position: .unspecified
            )
            screenCaptureSession.devices.forEach { device in
                print("Found Continuity device: \(device.localizedName), modelID: \(device.modelID)")
                handleContinuityDevice(device)
            }
        }
        
        // Then check for other external devices
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        
        discoverySession.devices.forEach { device in
            handleDeviceConnection(device)
        }
    }
    
    private func handleContinuityDevice(_ device: AVCaptureDevice) {
        print("Setting up Continuity device: \(device.localizedName)")
        
        do {
            // Try to lock device for configuration
            try device.lockForConfiguration()
            
            // Enable Continuity Camera features if available
            if device.isContinuityCamera {
                print("Device supports Continuity Camera")
            }
            
            device.unlockForConfiguration()
            
            // Add the device to our list
            addUSBDevice(device)
            
        } catch {
            print("Failed to configure Continuity device: \(error.localizedDescription)")
        }
    }
    
    private func handleDeviceConnection(_ device: AVCaptureDevice) {
        print("Found device: \(device.localizedName), type: \(device.deviceType), modelID: \(device.modelID)")
        
        // Only add external or continuity devices, skip built-in cameras
        if device.deviceType == .continuityCamera || 
           (device.deviceType == .external && !device.modelID.contains("built-in")) {
            addUSBDevice(device)
        }
    }
    
    private func addUSBDevice(_ device: AVCaptureDevice) {
        DispatchQueue.main.async {
            let deviceType: String
            let deviceName: String
            
            switch device.deviceType {
            case .continuityCamera:
                deviceType = "Continuity Camera"
                deviceName = device.localizedName
            case .external:
                deviceType = "USB Camera"
                deviceName = device.localizedName
            default:
                deviceType = "External Device"
                deviceName = device.localizedName
            }
            
            let usbDevice = USBDevice(
                id: device.uniqueID,
                name: deviceName,
                type: deviceType
            )
            
            if !self.usbDevices.contains(usbDevice) {
                print("Adding external device: \(deviceName) (\(deviceType))")
                self.usbDevices.append(usbDevice)
            }
        }
    }
    
    private func removeUSBDevice(_ device: AVCaptureDevice) {
        DispatchQueue.main.async {
            self.usbDevices.removeAll { $0.id == device.uniqueID }
            if self.selectedUSBDevice?.id == device.uniqueID {
                self.connectionState = .disconnected
                self.selectedUSBDevice = nil
            }
        }
    }
    
    func connectToUSBDevice(_ device: USBDevice) {
        print("Connecting to device: \(device.name) (\(device.type))")
        connectionType = .usb
        selectedUSBDevice = device
        connectionState = .connected
        
        // Start the capture session for the selected device
        setupCaptureSession(for: device)
    }
    
    private func setupCaptureSession(for device: USBDevice) {
        // Clean up any existing session
        captureSession?.stopRunning()
        captureSession = nil
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        guard let captureDevice = discoverySession.devices.first(where: { $0.uniqueID == device.id }) else {
            print("Failed to find capture device: \(device.id)")
            return
        }
        
        do {
            print("Setting up capture session for device: \(device.name)")
            let session = AVCaptureSession()
            session.beginConfiguration()
            
            // Configure for high quality
            if device.type == "Continuity Camera" {
                session.sessionPreset = .photo
                print("Using photo preset for Continuity Camera")
            }
            
            // Try to lock device for configuration
            try captureDevice.lockForConfiguration()
            
            // Enable Continuity Camera features if available
            if captureDevice.isContinuityCamera {
                print("Enabling Continuity Camera features")
            }
            
            captureDevice.unlockForConfiguration()
            
            let input = try AVCaptureDeviceInput(device: captureDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                print("Added input for device: \(device.name)")
            }
            
            // Add video output
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                print("Added video output")
            }
            
            // Add photo output
            let photoOutput = AVCapturePhotoOutput()
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                self.photoOutput = photoOutput
                print("Added photo output")
            }
            
            session.commitConfiguration()
            
            self.captureSession = session
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                print("Capture session started for device: \(device.name)")
            }
            
        } catch {
            print("Failed to setup capture session: \(error.localizedDescription)")
            disconnectUSBDevice()
        }
    }
    
    func disconnectUSBDevice() {
        captureSession?.stopRunning()
        captureSession = nil
        connectionType = .wireless
        selectedUSBDevice = nil
        connectionState = .disconnected
        receivedImage = nil
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
        // Don't send frames if streaming is disabled
        guard isStreamEnabled else { return }
        
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastFrameTime >= minFrameInterval else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              connectionState == .connected,
              !connectedPeers.isEmpty else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        // Get the original dimensions
        let extent = ciImage.extent
        
        // Create CGImage at original resolution
        guard let cgImage = context.createCGImage(ciImage, from: extent) else { return }
        
        // Get device orientation
        let deviceOrientation = UIDevice.current.orientation
        let imageOrientation: UIImage.Orientation
        
        switch deviceOrientation {
        case .landscapeLeft:
            imageOrientation = .left
        case .landscapeRight:
            imageOrientation = .right
        case .portraitUpsideDown:
            imageOrientation = .down
        default:
            imageOrientation = .up
        }
        
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
        
        // Use lossless PNG for quality mode, high quality JPEG for others
        let imageData: Data?
        switch streamQuality {
        case .quality:
            imageData = image.pngData()  // Lossless PNG for 4K
        case .balanced, .performance:
            imageData = image.jpegData(compressionQuality: streamQuality.compressionQuality)  // High quality JPEG
        }
        
        guard let imageData = imageData else { return }
        
        // Create metadata dictionary with original dimensions
        let metadata: [String: Any] = [
            "orientation": imageOrientation.rawValue,
            "timestamp": currentTime,
            "width": extent.width,
            "height": extent.height,
            "quality": streamQuality.rawValue
        ]
        
        // Combine metadata and image data
        var combinedData = Data()
        if let metadataData = try? JSONSerialization.data(withJSONObject: metadata) {
            var metadataSize = UInt32(metadataData.count)
            let sizeData = Data(bytes: &metadataSize, count: MemoryLayout<UInt32>.size)
            combinedData.append(sizeData)
            combinedData.append(metadataData)
            combinedData.append(imageData)
        }
        
        // Adjust max size based on quality mode
        let maxSize: Int
        switch streamQuality {
        case .quality:
            maxSize = 8_000_000  // 8MB for 4K PNG
        case .balanced:
            maxSize = 4_000_000  // 4MB for 1080p
        case .performance:
            maxSize = 1_000_000  // 1MB for 720p
        }
        
        guard combinedData.count < maxSize else {
            print("Frame dropped: size \(combinedData.count) exceeds limit \(maxSize)")
            return
        }
        
        sendData(combinedData, to: connectedPeers)
        lastFrameTime = currentTime
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard connectionType == .usb else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        // Get the original dimensions
        let extent = ciImage.extent
        
        // Create CGImage at original resolution
        guard let cgImage = context.createCGImage(ciImage, from: extent) else { return }
        
        // Get device orientation
        let deviceOrientation = UIDevice.current.orientation
        let imageOrientation: UIImage.Orientation
        
        switch deviceOrientation {
        case .landscapeLeft:
            imageOrientation = .left
        case .landscapeRight:
            imageOrientation = .right
        case .portraitUpsideDown:
            imageOrientation = .down
        default:
            imageOrientation = .up
        }
        
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
        
        DispatchQueue.main.async {
            self.receivedImage = image
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Handle dropped frames if needed
        print("Dropped frame")
    }
    
    func capturePhoto(completion: @escaping (Bool) -> Void) {
        switch connectionType {
        case .usb:
            capturePhotoFromUSB(completion: completion)
        case .wireless:
            capturePhotoFromWireless(completion: completion)
        }
    }
    
    private func capturePhotoFromUSB(completion: @escaping (Bool) -> Void) {
        guard let photoOutput = photoOutput else {
            print("Photo output not available for USB")
            completion(false)
            return
        }
        
        self.photoCaptureCompletion = completion
        
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        
        print("Capturing photo from USB device...")
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    private func capturePhotoFromWireless(completion: @escaping (Bool) -> Void) {
        guard let currentImage = receivedImage else {
            print("No image available to capture")
            completion(false)
            return
        }
        
        print("Capturing current frame from wireless stream...")
        UIImageWriteToSavedPhotosAlbum(currentImage, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
        self.photoCaptureCompletion = completion
    }
    
    // AVCapturePhotoCaptureDelegate methods
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            photoCaptureCompletion?(false)
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("Failed to create image from photo data")
            photoCaptureCompletion?(false)
            return
        }
        
        print("Photo captured successfully, saving to library...")
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    
    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            print("Error saving photo: \(error.localizedDescription)")
            photoCaptureCompletion?(false)
        } else {
            print("Photo saved successfully")
            photoCaptureCompletion?(true)
        }
        photoCaptureCompletion = nil
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
        // Try to parse control messages first
        if let message = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            switch message["type"] {
            case "stream_state":
                if let enabled = message["enabled"] {
                    DispatchQueue.main.async {
                        self.isRemoteStreamEnabled = (enabled == "true")
                        // Clear received image if stream is disabled
                        if !self.isRemoteStreamEnabled {
                            self.receivedImage = nil
                        }
                    }
                }
                return
                
            case "quality_change":
                if let qualityMode = message["mode"] {
                    DispatchQueue.main.async {
                        if qualityMode.contains("Performance") {
                            self.streamQuality = .performance
                        } else if qualityMode.contains("Balanced") {
                            self.streamQuality = .balanced
                        } else if qualityMode.contains("Quality") {
                            self.streamQuality = .quality
                        }
                    }
                }
                return
                
            default:
                break
            }
        }
        
        // Handle image data
        guard data.count >= MemoryLayout<UInt32>.size else { return }
        
        let metadataSizeData = data.prefix(MemoryLayout<UInt32>.size)
        var metadataSize: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &metadataSize) { metadataSizeData.copyBytes(to: $0) }
        
        guard data.count >= MemoryLayout<UInt32>.size + Int(metadataSize) else { return }
        
        let metadataData = data.subdata(in: MemoryLayout<UInt32>.size..<(MemoryLayout<UInt32>.size + Int(metadataSize)))
        let imageData = data.subdata(in: (MemoryLayout<UInt32>.size + Int(metadataSize))..<data.count)
        
        if let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
           let orientationRawValue = metadata["orientation"] as? Int,
           let orientation = UIImage.Orientation(rawValue: orientationRawValue),
           let image = UIImage(data: imageData) {
            
            // Create a new image with the correct orientation
            if let cgImage = image.cgImage {
                let orientedImage = UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
                DispatchQueue.main.async {
                    self.receivedImage = orientedImage
                }
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