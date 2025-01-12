import SwiftUI
import AVFoundation

struct BroadcastView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var connectionManager = ConnectionManager()
    @State private var isZooming = false
    @State private var zoomScale: CGFloat = 1.0
    private let videoCaptureDelegate: VideoCaptureDelegate
    
    init() {
        let connectionManager = ConnectionManager()
        self._connectionManager = StateObject(wrappedValue: connectionManager)
        self.videoCaptureDelegate = VideoCaptureDelegate(connectionManager: connectionManager)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera Preview
                CameraPreviewView(previewLayer: cameraManager.previewLayer)
                    .edgesIgnoringSafeArea(.all)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / (isZooming ? zoomScale : 1.0)
                                isZooming = true
                                zoomScale = value
                                cameraManager.setZoom(cameraManager.zoomFactor * delta)
                            }
                            .onEnded { _ in
                                isZooming = false
                            }
                    )
                
                // Camera Controls Overlay
                VStack {
                    // Top Controls
                    HStack {
                        connectionStatusView
                            .padding(.leading)
                        
                        Spacer()
                        
                        // Stream Toggle Button
                        Button(action: {
                            connectionManager.isStreamEnabled.toggle()
                        }) {
                            Image(systemName: connectionManager.isStreamEnabled ? "video.fill" : "video.slash.fill")
                                .font(.system(size: 24))
                                .foregroundColor(connectionManager.isStreamEnabled ? .white : .red)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 8)
                        
                        Button(action: {
                            cameraManager.switchCamera()
                        }) {
                            Image(systemName: "camera.rotate.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.trailing)
                    }
                    .padding(.top, geometry.safeAreaInsets.top)
                    
                    Spacer()
                    
                    // Bottom Controls
                    VStack {
                        // Zoom indicator
                        if cameraManager.zoomFactor > 1.0 {
                            Text(String(format: "%.1fx", cameraManager.zoomFactor))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Capsule())
                                .padding(.bottom)
                        }
                        
                        // Camera mode indicator
                        Text(cameraManager.currentCamera == .front ? "Front Camera" : "Back Camera")
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                }
            }
        }
        .onAppear {
            setupVideoStreaming()
            cameraManager.startSession()
            connectionManager.startAdvertising()
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
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
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
