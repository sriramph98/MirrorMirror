import SwiftUI
import MultipeerConnectivity

// Orientation manager to handle video orientation
class OrientationManager: ObservableObject {
    @Published var currentOrientation: UIDeviceOrientation = .portrait
    
    init() {
        // Start monitoring device orientation
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
        self.currentOrientation = UIDevice.current.orientation
    }
}

struct ReceiverView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var orientationManager = OrientationManager()
    @State private var showConnectionError = false
    @State private var showQualityPicker = false
    @State private var imageOrientation: UIImage.Orientation = .up
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if !connectionManager.isRemoteStreamEnabled {
                VStack(spacing: 20) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    
                    Text("Stream Paused by Broadcaster")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            } else if let receivedImage = connectionManager.receivedImage {
                GeometryReader { geometry in
                    Image(uiImage: receivedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: min(geometry.size.width, CGFloat(receivedImage.size.width)),
                            maxHeight: min(geometry.size.height, CGFloat(receivedImage.size.height))
                        )
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .rotation3DEffect(
                            orientationRotationAngle,
                            axis: orientationRotationAxis
                        )
                        .background(Color.black)
                        .edgesIgnoringSafeArea(.all)
                }
            }
            
            if connectionManager.availablePeers.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                    
                    Text("Searching for broadcasters...")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            } else if connectionManager.connectionState != .connected {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Available Broadcasters")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(.top)
                        
                        ForEach(connectionManager.availablePeers, id: \.self) { peer in
                            Button(action: {
                                connectionManager.selectedPeer = peer
                                connectToPeer(peer)
                            }) {
                                HStack {
                                    Image(systemName: "video.fill")
                                        .foregroundColor(.white)
                                    
                                    Text(peer.displayName)
                                        .foregroundColor(.white)
                                    
                                    Spacer()
                                    
                                    if connectionManager.connectedPeers.contains(peer) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else if connectionManager.selectedPeer == peer && connectionManager.connectionState == .connecting {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                                .padding()
                                .background(Color.blue.opacity(0.3))
                                .cornerRadius(10)
                            }
                            .disabled(connectionManager.connectionState == .connecting)
                        }
                    }
                    .padding()
                }
            }
            
            if connectionManager.connectionState == .connected {
                VStack {
                    // Top status bar
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        Text("Connected to \(connectionManager.connectedPeers.first?.displayName ?? "")")
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.top)
                    
                    Spacer()
                    
                    // Bottom quality control
                    VStack(spacing: 8) {
                        // Quality mode indicator
                        HStack {
                            Image(systemName: qualityModeIcon)
                                .foregroundColor(.white)
                            Text("\(connectionManager.streamQuality.rawValue)")
                                .foregroundColor(.white)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        
                        // Quality selection buttons
                        VStack(spacing: 12) {
                            // Performance Mode Button
                            Button(action: {
                                connectionManager.streamQuality = .performance
                            }) {
                                HStack {
                                    Image(systemName: "speedometer")
                                    VStack(alignment: .leading) {
                                        Text("Performance")
                                            .fontWeight(.medium)
                                        Text("720p • 60 FPS")
                                            .font(.caption)
                                            .opacity(0.8)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(connectionManager.streamQuality == .performance ? Color.blue : Color.black.opacity(0.5))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                            
                            // Balanced Mode Button
                            Button(action: {
                                connectionManager.streamQuality = .balanced
                            }) {
                                HStack {
                                    Image(systemName: "dial.medium")
                                    VStack(alignment: .leading) {
                                        Text("Balanced")
                                            .fontWeight(.medium)
                                        Text("1080p • 60 FPS")
                                            .font(.caption)
                                            .opacity(0.8)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(connectionManager.streamQuality == .balanced ? Color.blue : Color.black.opacity(0.5))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                            
                            // Quality Mode Button
                            Button(action: {
                                connectionManager.streamQuality = .quality
                            }) {
                                HStack {
                                    Image(systemName: "4k.tv.fill")
                                    VStack(alignment: .leading) {
                                        Text("Quality")
                                            .fontWeight(.medium)
                                        Text("4K • 30 FPS")
                                            .font(.caption)
                                            .opacity(0.8)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(connectionManager.streamQuality == .quality ? Color.blue : Color.black.opacity(0.5))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 30)
                }
                .rotation3DEffect(
                    orientationRotationAngle,
                    axis: orientationRotationAxis
                )
            }
        }
        .alert("Connection Error", isPresented: $showConnectionError) {
            Button("OK", role: .cancel) {
                connectionManager.selectedPeer = nil
            }
        } message: {
            Text("Failed to connect to the selected device. Please try again.")
        }
        .onChange(of: connectionManager.connectionState) { newState in
            if newState == .disconnected && connectionManager.selectedPeer != nil {
                showConnectionError = true
            }
        }
        .onAppear {
            connectionManager.startBrowsing()
        }
        .onDisappear {
            connectionManager.stopBrowsing()
        }
    }
    
    // Helper computed properties for orientation handling
    private var orientationRotationAngle: Angle {
        switch orientationManager.currentOrientation {
        case .landscapeLeft: return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        case .portraitUpsideDown: return .degrees(180)
        default: return .degrees(0)
        }
    }
    
    private var orientationRotationAxis: (CGFloat, CGFloat, CGFloat) {
        switch orientationManager.currentOrientation {
        case .landscapeLeft, .landscapeRight:
            return (0, 0, 1) // Rotate around Z axis
        case .portraitUpsideDown:
            return (0, 0, 1) // Rotate around Z axis
        default:
            return (0, 0, 1)
        }
    }
    
    private func connectToPeer(_ peer: MCPeerID) {
        connectionManager.invitePeer(peer)
    }
    
    private var qualityModeIcon: String {
        switch connectionManager.streamQuality {
        case .performance:
            return "speedometer"
        case .balanced:
            return "dial.medium"
        case .quality:
            return "4k.tv.fill"
        }
    }
} 