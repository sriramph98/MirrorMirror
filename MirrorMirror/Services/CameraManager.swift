import AVFoundation
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var zoomFactor: CGFloat = 1.0
    @Published var currentCamera: AVCaptureDevice.Position = .back
    @Published var availableCameras: [AVCaptureDevice.Position] = []
    @Published var availableZoomFactors: [CGFloat] = []
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
    private var deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInTripleCamera,
        .builtInTrueDepthCamera
    ]
    
    private func updateAvailableZoomFactors() {
        var factors: Set<CGFloat> = []
        
        for device in availableDevices {
            if device.deviceType == .builtInUltraWideCamera {
                factors.insert(0.5)
            } else if device.deviceType == .builtInWideAngleCamera {
                factors.insert(1.0)
            } else if device.deviceType == .builtInTelephotoCamera {
                // Get the actual max optical zoom factor for the telephoto lens
                let format = device.activeFormat
                let maxZoom = format.videoMaxZoomFactor
                if maxZoom >= 2.0 {
                    factors.insert(2.0)
                }
                if maxZoom >= 3.0 {
                    factors.insert(3.0)
                }
                if maxZoom >= 5.0 {
                    factors.insert(5.0)
                }
            }
        }
        
        // Update the published array with sorted zoom factors
        availableZoomFactors = Array(factors).sorted()
    }
    
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
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: currentCamera
        ).devices.sorted { first, second in
            first.deviceType.nativeZoomFactor < second.deviceType.nativeZoomFactor
        }
        
        // Update available zoom factors
        updateAvailableZoomFactors()
        
        // Start with the wide-angle camera if available, otherwise use the first available device
        guard let device = availableDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) 
              ?? availableDevices.first else { return }
        
        currentDevice = device
        zoomFactor = device.deviceType.nativeZoomFactor
        
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
    
    func setZoom(_ factor: CGFloat) {
        guard let session = captureSession else { return }
        
        // Determine which device to use based on the requested zoom factor
        let targetDevice: AVCaptureDevice?
        
        switch factor {
        case 0.5:
            targetDevice = availableDevices.first { $0.deviceType == .builtInUltraWideCamera }
        case 1.0:
            targetDevice = availableDevices.first { $0.deviceType == .builtInWideAngleCamera }
        case 2.0, 3.0, 5.0:
            targetDevice = availableDevices.first { $0.deviceType == .builtInTelephotoCamera }
        default:
            targetDevice = currentDevice
        }
        
        if let device = targetDevice {
            if device != currentDevice {
                switchToCamera(device)
            }
            
            do {
                try device.lockForConfiguration()
                // For ultra-wide, we need to handle it differently
                if device.deviceType == .builtInUltraWideCamera && factor == 0.5 {
                    // Ultra-wide cameras typically use zoom factor 1.0 internally
                    device.videoZoomFactor = 1.0
                } else {
                    // For other cameras, ensure we're within the valid zoom range
                    let minZoom = device.minAvailableVideoZoomFactor
                    let maxZoom = device.maxAvailableVideoZoomFactor
                    let zoomValue = max(minZoom, min(factor, maxZoom))
                    device.videoZoomFactor = zoomValue
                }
                device.unlockForConfiguration()
                
                // Update the published zoom factor
                zoomFactor = factor
            } catch {
                print("Error setting zoom: \(error.localizedDescription)")
            }
        }
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
                
                // Configure device format for the specific lens
                try newDevice.lockForConfiguration()
                
                // Find the format that matches our desired lens
                let formats = newDevice.formats.filter { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let width = CGFloat(dimensions.width)
                    let height = CGFloat(dimensions.height)
                    let maxDimension = max(width, height)
                    
                    // Filter for high-quality formats that support our desired frame rate
                    return maxDimension >= 1920 && format.videoSupportedFrameRateRanges.contains { range in
                        range.maxFrameRate >= 60
                    }
                }
                
                if let bestFormat = formats.first {
                    newDevice.activeFormat = bestFormat
                    
                    // Set initial zoom factor based on device type
                    if newDevice.deviceType == .builtInUltraWideCamera {
                        newDevice.videoZoomFactor = 1.0  // Use 1.0 for ultra-wide
                    } else {
                        let minZoom = newDevice.minAvailableVideoZoomFactor
                        let maxZoom = newDevice.maxAvailableVideoZoomFactor
                        let zoomValue = max(minZoom, min(zoomFactor, maxZoom))
                        newDevice.videoZoomFactor = zoomValue
                    }
                    
                    // Configure frame rate
                    if let range = bestFormat.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= 60 }) {
                        newDevice.activeVideoMinFrameDuration = range.minFrameDuration
                        newDevice.activeVideoMaxFrameDuration = range.minFrameDuration
                    }
                }
                
                newDevice.unlockForConfiguration()
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
        // Switch between front and back cameras
        currentCamera = currentCamera == .front ? .back : .front
        
        // Get available devices for the new position
        availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: currentCamera
        ).devices.sorted { first, second in
            first.deviceType.nativeZoomFactor < second.deviceType.nativeZoomFactor
        }
        
        // Update available zoom factors for the new position
        updateAvailableZoomFactors()
        
        // Start with wide-angle camera
        if let device = availableDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) 
            ?? availableDevices.first {
            switchToCamera(device)
            zoomFactor = device.deviceType.nativeZoomFactor
        }
    }
}

// Extension to handle device type zoom factors
private extension AVCaptureDevice.DeviceType {
    var nativeZoomFactor: CGFloat {
        switch self {
        case .builtInUltraWideCamera:
            return 0.5
        case .builtInWideAngleCamera:
            return 1.0
        case .builtInTelephotoCamera:
            // Check if this is a 3x or 5x telephoto lens
            // This would require checking the actual device model
            // For now, we'll use the device's actual zoom factor
            return 2.0
        default:
            return 1.0
        }
    }
} 