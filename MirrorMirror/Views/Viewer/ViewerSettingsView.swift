import SwiftUI

struct ViewerSettingsView: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss
    @State private var turnURL = ConnectionPreferences.turnURL
    @State private var turnUsername = ConnectionPreferences.turnUsername
    @State private var turnCredential = ConnectionPreferences.turnCredential

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("This device", value: DeviceIdentity.name)
                    LabeledContent("Watch away from home", value: hub.cloudAvailable ? "On (iCloud)" : "Off")
                } footer: {
                    if !hub.cloudAvailable {
                        Text(CloudRelay.shared.isConfigured
                             ? "Sign in to iCloud in Settings to watch cameras from anywhere and get alerts. On the same Wi-Fi everything works without it."
                             : "This build has no iCloud capability, so only cameras on the same network can be watched.")
                    }
                }

                Section {
                    ForEach(hub.cameras) { camera in
                        Toggle(camera.name, isOn: Binding(get: { camera.notificationsEnabled },
                                                          set: { hub.setNotifications(camera, enabled: $0) }))
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Motion, sound, low battery and overheating alerts from each camera.")
                }

                Section {
                    TextField("turn:turn.example.com:3478", text: $turnURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $turnUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Credential", text: $turnCredential)
                } header: {
                    Text("Relay server (optional)")
                } footer: {
                    Text("Most networks connect directly. If a camera never connects from a particular network (some cellular carriers and offices block it), add a TURN relay you trust here. Video through a relay is still end-to-end encrypted.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        ConnectionPreferences.turnURL = turnURL
                        ConnectionPreferences.turnUsername = turnUsername
                        ConnectionPreferences.turnCredential = turnCredential
                        dismiss()
                    }
                }
            }
        }
    }
}
