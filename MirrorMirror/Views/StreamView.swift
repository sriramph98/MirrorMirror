import SwiftUI
import MultipeerConnectivity

struct StreamView: View {
    @StateObject private var orientationManager = OrientationManager()
    @ObservedObject var connectionManager: ConnectionManager
    @State private var showCaptureConfirmation = false
    @State private var showQualityMenu = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    
                    // Stream Preview
                    ZStack {
                        if let receivedImage = connectionManager.receivedImage {
                            Image(uiImage: receivedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: min(geometry.size.width - 48, geometry.size.height * 0.75 * 0.75))
                                .frame(height: min(geometry.size.height * 0.75, (geometry.size.width - 48) * 4/3))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.5))
                                .frame(width: min(geometry.size.width - 48, geometry.size.height * 0.75 * 0.75))
                                .frame(height: min(geometry.size.height * 0.75, (geometry.size.width - 48) * 4/3))
                                .overlay(
                                    VStack(spacing: 20) {
                                        Image(systemName: "video.slash.fill")
                                            .font(.system(size: 50))
                                            .foregroundColor(.red)
                                        
                                        Text("Stream Paused")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                    }
                                )
                        }
                    }
                    
                    Spacer()
                    
                    // Bottom Controls
                    HStack {
                        // Quality Button
                        Button(action: {
                            showQualityMenu = true
                        }) {
                            Image(systemName: qualityModeIcon)
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 24)
                        .confirmationDialog("Streaming Quality", isPresented: $showQualityMenu, titleVisibility: .visible) {
                            Button("Performance (720p 60FPS)") {
                                connectionManager.streamQuality = .performance
                            }
                            Button("Quality (1080p 60FPS)") {
                                connectionManager.streamQuality = .quality
                            }
                        } message: {
                            Text("Select streaming quality")
                        }
                        
                        Spacer()
                        
                        // Capture Button
                        Button(action: {
                            // Capture frame from video stream
                            connectionManager.captureFrame { success in
                                if success {
                                    showCaptureConfirmation = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        showCaptureConfirmation = false
                                    }
                                }
                            }
                        }) {
                            Image("captureButton")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 72, height: 72)
                        }
                        
                        Spacer()
                        
                        // Settings Button
                        Button(action: {
                            // Show settings
                        }) {
                            Image(systemName: "gear")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .padding(.trailing, 24)
                    }
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom + 20, 30))
                }
            }
            
            // Close Button and Status
            VStack {
                HStack {
                    Button(action: {
                        connectionManager.connectionState = .disconnected
                        connectionManager.selectedPeer = nil
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
            
            // Capture Confirmation Overlay
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
                .cornerRadius(16)
            }
        }
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.all)
    }
    
    private var connectionStatusColor: Color {
        switch connectionManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected, .failed:
            return .red
        }
    }
    
    private var connectionStatusText: String {
        switch connectionManager.connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }
    
    private var qualityModeIcon: String {
        switch connectionManager.streamQuality {
        case .performance:
            return "speedometer"
        case .quality:
            return "4k.tv.fill"
        }
    }
} 