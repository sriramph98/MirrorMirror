import SwiftUI
import AVFoundation

struct BroadcastView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var cameraManager: CameraManager
    @State private var isZooming = false
    @State private var zoomScale: CGFloat = 1.0
    @Environment(\.dismiss) private var dismiss
    private let videoCaptureDelegate: VideoCaptureDelegate
    
    init() {
        let connectionManager = ConnectionManager()
        connectionManager.isStreamEnabled = true
        self._connectionManager = StateObject(wrappedValue: connectionManager)
        self._cameraManager = StateObject(wrappedValue: CameraManager(connectionManager: connectionManager))
        self.videoCaptureDelegate = VideoCaptureDelegate(connectionManager: connectionManager)
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    
                    // Camera Preview with Zoom Level
                    ZStack {
                        // Camera Preview
                        CameraPreviewView(previewLayer: cameraManager.previewLayer)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: min(geometry.size.width - 48, geometry.size.height * 0.75 * 0.75))
                            .frame(height: min(geometry.size.height * 0.75, (geometry.size.width - 48) * 4/3))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                        
                        // Zoom Level Overlay
                        VStack {
                            Spacer()
                            Text(String(format: "%.1fx", cameraManager.zoomFactor))
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Capsule())
                                .padding(.bottom, 16)
                                .onTapGesture {
                                    // Get current zoom factor index
                                    if let currentIndex = cameraManager.availableZoomFactors.firstIndex(of: cameraManager.zoomFactor) {
                                        // Get next zoom factor (cycle back to first if at end)
                                        let nextIndex = (currentIndex + 1) % cameraManager.availableZoomFactors.count
                                        let nextZoom = cameraManager.availableZoomFactors[nextIndex]
                                        cameraManager.setZoom(nextZoom)
                                    } else {
                                        // If current zoom is not in list, reset to first available zoom
                                        if let firstZoom = cameraManager.availableZoomFactors.first {
                                            cameraManager.setZoom(firstZoom)
                                        }
                                    }
                                }
                        }
                    }
                    
                    Spacer()
                    
                    // Bottom Controls
                    HStack {
                        // Flip Camera Button
                        Button(action: {
                            cameraManager.switchCamera()
                        }) {
                            Image(systemName: "camera.rotate.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 24)
                        
                        Spacer()
                        
                        // Capture Button
                        Button(action: {
                            // Capture logic here
                        }) {
                            Image("captureButton")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 72, height: 72)
                        }
                        
                        Spacer()
                        
                        // Stream Toggle Button
                        Button(action: {
                            connectionManager.isStreamEnabled.toggle()
                        }) {
                            Image(systemName: connectionManager.isStreamEnabled ? "video.fill" : "video.slash.fill")
                                .font(.system(size: 24))
                                .foregroundColor(connectionManager.isStreamEnabled ? .white : .red)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 24)
                    }
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom + 20, 30))
                }
            }
            
            // Close Button (keep on top)
            VStack {
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(.leading, 24)
                    
                    Spacer()
                    
                    // Connection Status
                    HStack {
                        Circle()
                            .fill(connectionStatusColor)
                            .frame(width: 8, height: 8)
                        Text(connectionStatusText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.trailing, 24)
                }
                .padding(.top, 50)
                
                Spacer()
            }
        }
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            setupVideoStreaming()
            cameraManager.startSession()
            connectionManager.startAdvertising()
            startBroadcasting()
        }
        .onDisappear {
            cameraManager.stopSession()
            connectionManager.stopAdvertising()
        }
    }
    
    private func setupVideoStreaming() {
        cameraManager.setDelegate(videoCaptureDelegate)
    }
    
    private var connectionStatusView: some View {
        HStack {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 10, height: 10)
            
            Text(connectionStatusText)
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
    }
    
    private var connectionStatusColor: Color {
        switch connectionManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        case .failed:
            return .red
        }
    }
    
    private var connectionStatusText: String {
        switch connectionManager.connectionState {
        case .connected:
            return "Connected (\(connectionManager.connectedPeers.count))"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Waiting for connection"
        case .failed:
            return "Connection failed"
        }
    }
    
    private func startBroadcasting() {
        let deviceInfo = getDeviceInfo()
        broadcastDeviceInfo(deviceInfo)
        
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let deviceInfo = getDeviceInfo()
            broadcastDeviceInfo(deviceInfo)
        }
    }
    
    private func getDeviceInfo() -> DeviceInfo {
        return DeviceInfo()
    }
    
    private func broadcastDeviceInfo(_ deviceInfo: DeviceInfo) {
        connectionManager.broadcast(deviceInfo: deviceInfo)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear // Remove black background
        
        if let previewLayer = previewLayer {
            previewLayer.frame = view.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = previewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
} 
