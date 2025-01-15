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

class ReceiverViewModel: NSObject, ObservableObject {
    @Published var devices: [DeviceInfo] = []
    
    override init() {
        super.init()
        setupNotifications()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateDeviceList),
            name: .deviceInfoReceived,
            object: nil
        )
    }
    
    @objc private func updateDeviceList(_ notification: Notification) {
        if let deviceInfo = notification.userInfo?["deviceInfo"] as? DeviceInfo {
            DispatchQueue.main.async {
                self.devices.append(deviceInfo)
            }
        }
    }
}

struct DeviceListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connectionManager: ConnectionManager
    let onDeviceSelected: (MCPeerID) -> Void
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        if connectionManager.availablePeers.isEmpty {
                            HStack {
                                Spacer()
                                Text("Searching for broadcasters...")
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                            .padding()
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(10)
                        } else {
                            ForEach(connectionManager.availablePeers, id: \.self) { peer in
                                Button(action: {
                                    onDeviceSelected(peer)
                                    dismiss()
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
                            }
                        }
                    }
                    .padding()
                    
                    Spacer()
                }
            }
            .navigationTitle("Available Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            connectionManager.startBrowsing()
        }
        .onDisappear {
            connectionManager.stopBrowsing()
        }
    }
}

struct ReceiverView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var viewModel = ReceiverViewModel()
    @State private var showConnectionError = false
    @State private var showDeviceList = true
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if connectionManager.connectionState == .connected {
                StreamView(connectionManager: connectionManager)
            }
        }
        .sheet(isPresented: $showDeviceList) {
            DeviceListView(connectionManager: connectionManager) { peer in
                connectToPeer(peer)
            }
        }
        .alert("Connection Error", isPresented: $showConnectionError) {
            Button("OK", role: .cancel) {
                connectionManager.selectedPeer = nil
                showDeviceList = true
            }
        } message: {
            Text("Failed to connect to the selected device. Please try again.")
        }
        .onAppear {
            connectionManager.startBrowsing()
        }
        .onDisappear {
            connectionManager.stopBrowsing()
        }
    }
    
    private func connectToPeer(_ peer: MCPeerID) {
        connectionManager.invitePeer(peer)
    }
} 