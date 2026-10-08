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
        DebugSnapshots.startIfRequested()
    }

    var body: some Scene {
        mainWindow
        cameraWindows
    }

    /// The app: a stack on iPhone, a split view on iPad and the Mac.
    private var mainWindow: some Scene {
        let group = WindowGroup {
            if DebugSupport.showGallery {
                DesignSystemGallery()
            } else {
                RootView()
                .environmentObject(hub)
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if AppRoutes.shared.handle(url) { return }
                    if let invite = PairingInvite(string: url.absoluteString) { pendingInvite = invite }
                }
                .onAppear {
                    // `-MMScreen confirm -MMPairURL …`: show the invite confirmation (screenshots).
                    if ScreenHook.screen == "confirm", let url = DebugSupport.pairURL { pendingInvite = PairingInvite(string: url) }
                }
                .sheet(item: $pendingInvite) { invite in
                    AddCameraConfirmation(invite: invite)
                        .environmentObject(hub)
                        .tint(Palette.accent)
                        .presentationDetents([.medium, .large])
                        .mirrorSheet()
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        return group
            .defaultSize(width: 1180, height: 760)
            .commands { MirrorCommands() }
        #else
        return group
        #endif
    }

    /// One camera per window (Mac; iPad when multiple windows are allowed). Opened with
    /// `openWindow(value: camera.id)`; the hub keeps the connection alive.
    private var cameraWindows: some Scene {
        let group = WindowGroup("Camera", for: PairedCamera.ID.self) { $cameraID in
            CameraWindowRoot(cameraID: cameraID)
                .environmentObject(hub)
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
        }
        #if targetEnvironment(macCatalyst)
        return group.defaultSize(width: 960, height: 620)
        #else
        return group
        #endif
    }
}

/// Gives a camera window its own command router, so the menus act on it while it is key.
private struct CameraWindowRoot: View {
    let cameraID: String?
    @StateObject private var router = CommandRouter(hub: ViewerHub.shared)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraWindowView(cameraID: cameraID)
            .environment(\.commandRouter, router)
            .focusedSceneObject(router)
            .onAppear { router.becomeActive() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { router.becomeActive() } }
    }
}

extension PairingInvite: Identifiable {
    var id: String { key.cameraID }
}

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    #if targetEnvironment(macCatalyst)
    /// Mac menu bar: drop UIKit's stock File › New Window so ⌘N can be Add Camera (cameras open
    /// their own windows from the View menu), and the Format menu, which nothing here uses.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .newScene)
        builder.remove(menu: .format)
        MacCameraMenu.install(in: builder)
    }

    /// Camera menu items are enabled only while the key window can act on them.
    override func validate(_ command: UICommand) {
        if let can = MacCameraMenu.canPerform(command.action) {
            command.attributes = can ? [] : .disabled
        } else {
            super.validate(command)
        }
    }

    /// Menu actions arrive here from the responder chain; the delegate must claim them.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if MacCameraMenu.canPerform(action) != nil { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    #endif

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if CloudRelay.shared.isConfigured { application.registerForRemoteNotifications() }
        // Early, so a watch request that launches the app in the background is handled.
        WatchRelay.shared.activate()
        LiveActivities.activate()
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
