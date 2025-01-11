//
//  ContentView.swift
//  MirrorMirror
//
//  Created by Sriram P H on 1/11/25.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedMode: CameraMode?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Text("MirrorMirror")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Select Mode")
                    .font(.title2)
                
                ForEach(CameraMode.allCases, id: \.self) { mode in
                    NavigationLink(destination: modeView(for: mode)) {
                        ModeSelectionButton(mode: mode, isSelected: selectedMode == mode)
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func modeView(for mode: CameraMode) -> some View {
        switch mode {
        case .broadcast:
            BroadcastView()
        case .view:
            ReceiverView()
        }
    }
}

struct ModeSelectionButton: View {
    let mode: CameraMode
    let isSelected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: mode == .broadcast ? "video.fill" : "eye.fill")
                .font(.title2)
            
            Text(mode.rawValue)
                .font(.title3)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue : Color.blue.opacity(0.1))
        )
        .foregroundColor(isSelected ? .white : .blue)
    }
}

#Preview {
    ContentView()
}
