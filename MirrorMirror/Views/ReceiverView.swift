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
    @State private var showCaptureConfirmation = false
    
    var body: some View {
        NavigationView {
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
                
                if connectionManager.connectionState == .connected {
                    VStack {
                        // Custom Navigation Bar
                        HStack {
                            Button(action: {
                                // Action to go back
                            }) {
                                Image(systemName: "chevron.left")
                                    .foregroundColor(.white)
                                    .padding()
                            }
                            Spacer()
                            Text("Available Devices")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        
                        Spacer()
                        
                        // Capture Button
                        Button(action: {
                            connectionManager.capturePhoto { success in
                                if success {
                                    showCaptureConfirmation = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        showCaptureConfirmation = false
                                    }
                                }
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 70, height: 70)
                                
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 80, height: 80)
                            }
                            .shadow(radius: 5)
                        }
                        .padding(.bottom, 20)
                        
                        // Quality controls
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
                
                if connectionManager.connectionState != .connected {
                    ScrollView {
                        VStack(spacing: 24) {
                            // Removed Wireless Section
                            // This section is now deleted
                            /*
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundColor(.blue)
                                    Text("Wireless Connections")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                }
                                .padding(.top)
                                
                                if connectionManager.availablePeers.isEmpty {
                                    HStack {
                                        Spacer()
                                        Text("Searching for wireless broadcasters...")
                                            .foregroundColor(.gray)
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(10)
                                } else {
                                    ForEach(connectionManager.availablePeers, id: \.self) { peer in
                                        Button(action: {
                                            connectionManager.selectedPeer = peer
                                            connectToPeer(peer)
                                        }) {
                                            HStack {
                                                Image(systemName: "iphone")
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
                            }
                            */
                        }
                        .padding()
                    }
                }
                
                // Capture confirmation overlay
                if showCaptureConfirmation {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        Text("Photo Captured")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(15)
                }
                
                // Looking for devices banner
                VStack {
                    Spacer() // Push the banner to the bottom
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.blue)
                            .font(.system(size: 24))
                        
                        VStack(alignment: .leading) {
                            Text("Looking for Devices")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Make sure both devices are on the same network with Wi-Fi and Bluetooth turned on.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(.leading, 8)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
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