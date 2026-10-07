//
//  MirrorMirrorApp.swift
//  MirrorMirror
//
//  Created by Sriram P H on 1/11/25.
//

import SwiftUI
import MirrorUI
import CloudKit
import UserNotifications

@main
struct MirrorMirrorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var hub = ViewerHub.shared
    @State private var pendingInvite: PairingInvite?

    init() {
        Fonts.register()
    }

    var body: some Scene {
        WindowGroup {
            if DebugSupport.showGallery {
                DesignSystemGallery()
            } else {
                HomeView()
                .environmentObject(hub)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if let invite = PairingInvite(string: url.absoluteString) { pendingInvite = invite }
                }
                .sheet(item: $pendingInvite) { invite in
                    AddCameraConfirmation(invite: invite)
                        .environmentObject(hub)
                        .tint(Theme.accent)
                        .presentationDetents([.medium])
                }
            }
        }
    }
}

extension PairingInvite: Identifiable {
    var id: String { key.cameraID }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if CloudRelay.shared.isConfigured { application.registerForRemoteNotifications() }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        RecordingStore.shared.flush()
    }

    // Show banners even while the app is open (e.g. watching a different camera).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            let hub = ViewerHub.shared
            if let id = userInfo["cameraID"] as? String {
                if let seconds = userInfo["eventDate"] as? Double {
                    hub.pendingReplay = (id, Date(timeIntervalSince1970: seconds))
                }
                hub.pendingOpenCameraID = id
            } else if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
                      let subscriptionID = notification.subscriptionID,
                      let camera = hub.camera(forSubscriptionID: subscriptionID) {
                hub.pendingOpenCameraID = camera.id
            }
        }
    }
}

enum Notifications {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
