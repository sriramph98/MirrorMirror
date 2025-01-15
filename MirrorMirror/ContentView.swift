//
//  ContentView.swift
//  MirrorMirror
//
//  Created by Sriram P H on 1/11/25.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedMode: CameraMode?
    @State private var hasCapturedPhotos: Bool = false
    @State private var showDeviceList = false
    @StateObject private var connectionManager = ConnectionManager()
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mirror")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Mirror")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "EEED7C"))
                }
                .padding(.top)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(spacing: 16) {
                    NavigationLink(destination: BroadcastView()) {
                        ModeSelectionButton(mode: .broadcast, isSelected: selectedMode == .broadcast)
                            .frame(maxWidth: .infinity)
                    }
                    
                    Button(action: {
                        showDeviceList = true
                    }) {
                        ModeSelectionButton(mode: .view, isSelected: selectedMode == .view)
                            .frame(maxWidth: .infinity)
                    }
                }
                
                Spacer()
                
                // Updated Captures Button
                NavigationLink(destination: Text("Captures View")) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .opacity(hasCapturedPhotos ? 1 : 0.5)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Captures")
                                .font(.title3)
                                .fontWeight(.medium)
                            
                            Text("Check out all images from your session")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .opacity(hasCapturedPhotos ? 1 : 0.5)
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        EllipticalGradient(
                            stops: [
                                Gradient.Stop(color: Color(red: 0.11, green: 0.11, blue: 0.11), location: 0.00),
                                Gradient.Stop(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1.00),
                            ],
                            center: UnitPoint(x: 0, y: -0.61)
                        )
                        .opacity(hasCapturedPhotos ? 1 : 0.5)
                    )
                    .cornerRadius(24)
                    .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .inset(by: 0.5)
                            .stroke(.white.opacity(hasCapturedPhotos ? 0.14 : 0.07), lineWidth: 1)
                    )
                    .foregroundColor(.white)
                }
                .disabled(!hasCapturedPhotos)
            }
            .padding(.vertical)
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showDeviceList) {
            DeviceListView(connectionManager: connectionManager) { peer in
                connectionManager.invitePeer(peer)
                if connectionManager.connectionState == .connecting {
                    // Navigate to StreamView after connection is initiated
                    selectedMode = .view
                }
            }
        }
        .fullScreenCover(isPresented: .init(
            get: { selectedMode == .view && connectionManager.connectionState == .connected },
            set: { if !$0 { selectedMode = nil } }
        )) {
            StreamView(connectionManager: connectionManager)
        }
        .onChange(of: connectionManager.connectionState) { newState in
            if newState == .connected && selectedMode == .view {
                showDeviceList = false
            }
        }
    }
}

struct ModeSelectionButton: View {
    let mode: CameraMode
    let isSelected: Bool
    
    var description: String {
        switch mode {
        case .broadcast:
            return "Stream your device's camera feed to another device seamlessly."
        case .view:
            return "View and control the camera feed from a paired device in real time."
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: mode == .broadcast ? "video.fill" : "eye.fill")
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(mode.rawValue)
                    .font(.title3)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            EllipticalGradient(
                stops: [
                    Gradient.Stop(color: Color(red: 0.11, green: 0.11, blue: 0.11), location: 0.00),
                    Gradient.Stop(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1.00),
                ],
                center: UnitPoint(x: 0, y: -0.61)
            )
        )
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .inset(by: 0.5)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .foregroundColor(.white)
    }
}

#Preview {
    ContentView()
}
