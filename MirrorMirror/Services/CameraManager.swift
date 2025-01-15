import AVFoundation
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var zoomFactor: CGFloat = 1.0
    @Published var currentCamera: AVCaptureDevice.Position = .back
    @Published var availableCameras: [AVCaptureDevice.Position] = []
    @Published var currentOrientation: UIDeviceOrientation = .portrait {
        didSet {
            updatePreviewLayerOrientation()
        }
    }
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentDevice: AVCaptureDevice?
    var videoDataDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    private let connectionManager: ConnectionManager
    
    // Zoom-related properties
    private var availableDevices: [AVCaptureDevice] = []
    private var currentZoomFactor: CGFloat = 1.0
    private var minAvailableZoomScale: CGFloat = 1.0
    private var maxAvailableZoomScale: CGFloat = 1.0
    
    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        super.init()
        setupOrientationObserver()
        checkAvailableCameras()
        setupCaptureSession()
    }
    
    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }
    
    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    
    @objc private func orientationChanged() {
        currentOrientation = UIDevice.current.orientation
    }
    
    private func updatePreviewLayerOrientation() {
        guard let connection = previewLayer?.connection else { return }
        
        let orientation = currentOrientation
        guard orientation.isValidInterfaceOrientation else { return }
        
        let videoOrientation: AVCaptureVideoOrientation
        switch orientation {
        case .landscapeLeft:
            videoOrientation = .landscapeRight
        case .landscapeRight:
            videoOrientation = .landscapeLeft
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        default:
            videoOrientation = .portrait
        }
        
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        
        // Update video output orientation
        if let videoConnection = videoOutput?.connection(with: .video),
           videoConnection.isVideoOrientationSupported {
            videoConnection.videoOrientation = videoOrientation
        }
    }
    
    private func checkAvailableCameras() {
        availableCameras = []
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil {
            availableCameras.append(.back)
        }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil {
            availableCameras.append(.front)
        }
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            availableCameras.append(.back)
        }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil {
            availableCameras.append(.back)
        }
    }
    
    private func setupCaptureSession() {
        let session = AVCaptureSession()
        
        // Set session preset based on quality mode
        switch connectionManager.streamQuality {
        case .quality:
            session.sessionPreset = .hd1920x1080 // 1080p
        case .performance:
            session.sessionPreset = .hd1280x720  // 720p
        }
        
        // Get all available devices for the current position
        availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera
            ],
            mediaType: .video,
            position: currentCamera
        ).devices
        
        // Start with the wide-angle camera if available
        guard let device = availableDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) 
              ?? availableDevices.first else { return }
        
        currentDevice = device
        updateZoomLimits()
        
        do {
            // Configure preview layer first
            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            self.previewLayer = previewLayer
            
            // Configure input
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            // Configure output
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.setSampleBufferDelegate(videoDataDelegate, queue: DispatchQueue(label: "videoQueue", qos: .userInteractive))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                self.videoOutput = videoOutput
                
                // Set initial orientation
                if let connection = videoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            
            // Configure frame rate
            try device.lockForConfiguration()
            
            // Set frame rate to 60 FPS for both quality modes
            let desiredFrameRate = CMTime(value: 1, timescale: 60)
            let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
            if let range = supportedRanges.first(where: { $0.maxFrameDuration <= desiredFrameRate && $0.minFrameDuration <= desiredFrameRate }) {
                device.activeVideoMinFrameDuration = range.minFrameDuration
                device.activeVideoMaxFrameDuration = range.minFrameDuration
            }
            
            device.videoZoomFactor = zoomFactor
            device.unlockForConfiguration()
            
            self.captureSession = session
            
            // Start the session
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
            
        } catch {
            print("Failed to setup camera: \(error.localizedDescription)")
        }
    }
    
    private func updateZoomLimits() {
        guard let device = currentDevice else { return }
        minAvailableZoomScale = 1.0
        maxAvailableZoomScale = device.maxAvailableVideoZoomFactor
        
        // Update current zoom factor if it's outside the new limits
        currentZoomFactor = max(minAvailableZoomScale, min(currentZoomFactor, maxAvailableZoomScale))
    }
    
    func setZoom(_ factor: CGFloat) {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Calculate the target zoom factor
            let targetZoomFactor = factor
            
            // Check if we need to switch cameras based on the zoom level
            if targetZoomFactor > device.maxAvailableVideoZoomFactor,
               let nextCamera = findNextCameraForZoom(currentZoomFactor: targetZoomFactor) {
                switchToCamera(nextCamera)
                return
            }
            
            // Apply zoom within the device's limits
            let newZoomFactor = max(1.0, min(targetZoomFactor, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = newZoomFactor
            currentZoomFactor = newZoomFactor
            zoomFactor = newZoomFactor
            
            device.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
        }
    }
    
    private func findNextCameraForZoom(currentZoomFactor: CGFloat) -> AVCaptureDevice? {
        let sortedDevices = availableDevices.sorted { first, second in
            first.deviceType.zoomFactor < second.deviceType.zoomFactor
        }
        
        for device in sortedDevices {
            if device.maxAvailableVideoZoomFactor >= currentZoomFactor {
                return device
            }
        }
        
        return nil
    }
    
    private func switchToCamera(_ newDevice: AVCaptureDevice) {
        guard let session = captureSession else { return }
        
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
            session.removeInput(currentInput)
        }
        
        do {
            // Add new input
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentDevice = newDevice
                updateZoomLimits()
            }
            
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            print("Error switching cameras: \(error.localizedDescription)")
        }
    }
    
    func setDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        self.videoDataDelegate = delegate
        videoOutput?.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "videoQueue"))
    }
    
    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }
    
    func stopSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }
    
    func switchCamera() {
        guard let session = captureSession else { return }
        
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
            session.removeInput(currentInput)
        }
        
        // Switch camera position
        currentCamera = currentCamera == .front ? .back : .front
        
        // Get all available devices for the new position
        availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera
            ],
            mediaType: .video,
            position: currentCamera
        ).devices
        
        // Start with wide-angle camera for the new position
        guard let device = availableDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
              ?? availableDevices.first else {
            session.commitConfiguration()
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentDevice = device
                
                // Reset zoom for front camera
                if currentCamera == .front {
                    zoomFactor = 1.0
                    currentZoomFactor = 1.0
                }
                
                // Configure frame rate
                try device.lockForConfiguration()
                device.videoZoomFactor = zoomFactor
                
                // Set frame rate to 60 FPS
                let desiredFrameRate = CMTime(value: 1, timescale: 60)
                let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
                if let range = supportedRanges.first(where: { $0.maxFrameDuration <= desiredFrameRate && $0.minFrameDuration <= desiredFrameRate }) {
                    device.activeVideoMinFrameDuration = range.minFrameDuration
                    device.activeVideoMaxFrameDuration = range.minFrameDuration
                }
                
                device.unlockForConfiguration()
                updateZoomLimits()
            }
            
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            print("Error switching cameras: \(error.localizedDescription)")
        }
    }
}

// Extension to handle device type zoom factors
private extension AVCaptureDevice.DeviceType {
    var zoomFactor: CGFloat {
        switch self {
        case .builtInUltraWideCamera:
            return 0.5
        case .builtInWideAngleCamera:
            return 1.0
        case .builtInTelephotoCamera:
            return 2.0
        default:
            return 1.0
        }
    }
} 