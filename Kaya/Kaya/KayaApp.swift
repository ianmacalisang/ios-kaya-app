//
//  KayaApp.swift
//  Kaya
//
//  Created by Ian Andrew Macalisang on 10/9/26.
//

import SwiftData
import SwiftUI
import UserNotifications

/// Notification taps land here — a reminder's "Start now" action (or a
/// plain tap) hands the routine's ID to AppNavigation, and ContentView
/// opens it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show reminders as banners even while the app is open — they're
    /// meant to be seen, not hoarded in Notification Center.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["routineID"] as? String {
            AppNavigation.shared.routineRequestID = id
        }
        completionHandler()
    }
}

@main
struct KayaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = Self.makeContainer()

    /// Open the persistent store; if it's corrupt or a migration failed,
    /// delete it and start clean. A crash loop at launch would leave the
    /// app permanently dead — losing data is bad, but an app that never
    /// opens is worse. The data was unreadable either way.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            Routine.self,
            RoutineStepRecord.self,
            UserProfile.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }

        NSLog("Kaya: persistent store failed to open — resetting it")
        // SQLite keeps companions next to the store file.
        let base = config.url.path
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: base + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }

        // Last resort — storage itself is broken (full disk, permissions).
        // In-memory keeps the app usable for this session.
        NSLog("Kaya: store reset failed — running in-memory this session")
        let memoryConfig = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [memoryConfig])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
