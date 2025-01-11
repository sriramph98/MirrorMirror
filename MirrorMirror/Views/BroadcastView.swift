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
                
                // Zoom Controls
                VStack {
                    Spacer()
                    
                    HStack {
                        Button(action: {
                            adjustZoom(-1)
                        }) {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        Text(String(format: "%.1fx", cameraManager.zoomFactor))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                        
                        Spacer()
                        
                        Button(action: {
                            adjustZoom(1)
                        }) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                    .padding()
                }
                
                // Connection Status
                VStack {
                    connectionStatusView
                    Spacer()
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
        }
        .padding()
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .padding(.top)
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
    
    private func adjustZoom(_ direction: CGFloat) {
        let newZoom = cameraManager.zoomFactor + (direction * 0.5)
        cameraManager.setZoom(newZoom)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        if let previewLayer = previewLayer {
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = previewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
} 
