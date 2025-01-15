import SwiftUI
import MultipeerConnectivity

struct StreamView: View {
    @StateObject private var orientationManager = OrientationManager()
    @ObservedObject var connectionManager: ConnectionManager
    @State private var showCaptureConfirmation = false
    
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
                }
            }
            
            // Overlay controls
            VStack {
                // Top bar with quality controls
                HStack {
                    Image(systemName: qualityModeIcon)
                        .foregroundColor(.white)
                    Text(connectionManager.streamQuality.description)
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(.top)
                
                Spacer()
                
                // Capture button
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
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
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
            return (0, 0, 1)
        case .portraitUpsideDown:
            return (0, 0, 1)
        default:
            return (0, 0, 1)
        }
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