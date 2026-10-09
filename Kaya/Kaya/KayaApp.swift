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

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Routine.self,
            RoutineStepRecord.self,
            UserProfile.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
