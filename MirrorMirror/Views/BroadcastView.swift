import SwiftUI
import AVFoundation

struct BroadcastView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var cameraManager: CameraManager
    @State private var isZooming = false
    @State private var zoomScale: CGFloat = 1.0
    private let videoCaptureDelegate: VideoCaptureDelegate
    
    init() {
        let connectionManager = ConnectionManager()
        self._connectionManager = StateObject(wrappedValue: connectionManager)
        self._cameraManager = StateObject(wrappedValue: CameraManager(connectionManager: connectionManager))
        self.videoCaptureDelegate = VideoCaptureDelegate(connectionManager: connectionManager)
    }
    
    var body: some View {
        NavigationView {
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
                                    .padding()
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            .padding(.leading, 20)
                            
                            Spacer()
                            
                            // Capture Button
                            Button(action: {
                                // Action to capture the photo or start/stop video recording
                                // Implement your capture logic here
                            }) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.red)
                                    .padding(15)
                                    .background(Color.white.opacity(0.5))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(Color.red, lineWidth: 2)
                                    )
                            }
                            
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
                            .padding(.trailing, 20)
                        }
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                    }
                }
            }
            .navigationBarTitle("Broadcast", displayMode: .inline)
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
