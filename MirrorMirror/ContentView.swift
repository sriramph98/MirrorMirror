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
                    Button(action: {
                        selectedMode = .broadcast
                    }) {
                        ModeSelectionButton(mode: .broadcast, isSelected: selectedMode == .broadcast)
                    }
                    
                    Button(action: {
                        showDeviceList = true
                    }) {
                        ModeSelectionButton(mode: .view, isSelected: selectedMode == .view)
                    }
                }
                
                Spacer()
                
                // Captures Button
                NavigationLink(destination: Text("Captures View")) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .opacity(hasCapturedPhotos ? 1 : 0.5)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Captures")
                                .font(.title3)
                                .fontWeight(.medium)
                            
                            Text("View all your captured photos and videos.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 36)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                    .background(
                        EllipticalGradient(
                            stops: [
                                Gradient.Stop(color: Color(red: 0.11, green: 0.11, blue: 0.11), location: 0.00),
                                Gradient.Stop(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1.00),
                            ],
                            center: UnitPoint(x: 0.48, y: -0.06)
                        )
                    )
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .inset(by: 0.75)
                            .stroke(.white.opacity(0.14), lineWidth: 1.5)
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
        .fullScreenCover(isPresented: .init(
            get: { selectedMode == .broadcast },
            set: { if !$0 { selectedMode = nil } }
        )) {
            BroadcastView()
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
        .padding(.vertical, 36)
                        .frame(maxWidth: .infinity, alignment: .leading)

        .background(
            EllipticalGradient(
                stops: [
                    Gradient.Stop(color: Color(red: 0.11, green: 0.11, blue: 0.11), location: 0.00),
                    Gradient.Stop(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1.00),
                ],
                center: UnitPoint(x: 0.48, y: -0.06)
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .inset(by: 0.75)
                .stroke(.white.opacity(0.14), lineWidth: 1.5)
        )
        .foregroundColor(.white)
    }
}

#Preview {
    ContentView()
}
