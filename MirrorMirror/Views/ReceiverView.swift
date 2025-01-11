import SwiftUI
import MultipeerConnectivity

struct ReceiverView: View {
    @StateObject private var connectionManager = ConnectionManager()
    @State private var showConnectionError = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let receivedImage = connectionManager.receivedImage {
                Image(uiImage: receivedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .edgesIgnoringSafeArea(.all)
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
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        Text("Connected to \(connectionManager.connectedPeers.first?.displayName ?? "")")
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    
                    Spacer()
                }
                .padding(.top)
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
    
    private func connectToPeer(_ peer: MCPeerID) {
        connectionManager.invitePeer(peer)
    }
} 