//
//  ReminderService.swift
//  Kaya
//
//  Gentle local reminders for scheduled routines. Opt-in: iOS asks once,
//  and the You tab can turn them off anytime. Copy stays pressure-free —
//  "ready when you are", never "you're late".
//

import Foundation
import SwiftUI
import UserNotifications

/// Navigation requests that cross view boundaries — the notification
/// delegate sets `routineRequestID`, ContentView switches to Routines,
/// and RoutinesView presents the routine.
@Observable
final class AppNavigation {
    static let shared = AppNavigation()
    var routineRequestID: String?
}

@Observable
final class ReminderService {
    static let shared = ReminderService()

    static let categoryID = "ROUTINE_REMINDER"
    static let startActionID = "START_NOW"

    var authorization: UNAuthorizationStatus = .notDetermined

    /// User-level kill switch — separate from the iOS permission.
    /// Views bind this key via @AppStorage so the toggle stays reactive.
    static let enabledKey = "kaya.remindersEnabled"
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private let center = UNUserNotificationCenter.current()

    private init() {
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [UNNotificationAction(
                    identifier: Self.startActionID,
                    title: "Start now",
                    options: [.foreground]
                )],
                intentIdentifiers: []
            )
        ])
        refreshStatus()
    }

    func refreshStatus() {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            authorization = settings.authorizationStatus
        }
    }

    /// The one iOS prompt — call only when there's a real schedule to
    /// protect, never at launch.
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        refreshStatus()
        return granted
    }

    // MARK: - Scheduling

    /// Rebuild every pending reminder from the saved routines — called on
    /// launch, so deleting a routine elsewhere can never leave a ghost.
    func syncAll(_ routines: [Routine]) {
        guard enabled else {
            center.removeAllPendingNotificationRequests()
            return
        }
        Task { @MainActor in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            center.removeAllPendingNotificationRequests()
            for routine in routines {
                schedule(for: routine)
            }
        }
    }

    /// Schedule (or clear) one routine's reminder.
    func sync(_ routine: Routine) {
        center.removePendingNotificationRequests(
            withIdentifiers: [routine.uuid, Self.inProgressID(for: routine)])
        guard enabled, authorization == .authorized else { return }
        schedule(for: routine)
    }

    func cancelReminders(for routine: Routine) {
        center.removePendingNotificationRequests(
            withIdentifiers: [routine.uuid, Self.inProgressID(for: routine)])
    }

    // MARK: - In-progress nudges

    /// Separate identifier space from scheduled reminders so a "come back"
    /// nudge never cancels the routine's real reminder.
    private static func inProgressID(for routine: Routine) -> String {
        "inprogress-" + routine.uuid
    }

    /// Re-arm "you're partway through" nudges for routines left mid-run —
    /// called when the app backgrounds, since banners also show in the
    /// foreground and would otherwise interrupt the routine itself.
    func syncInProgress(_ routines: [Routine]) {
        Task { @MainActor in
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix("inprogress-") }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard enabled else { return }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            for routine in routines where routine.hasStarted && !routine.isFinished {
                scheduleNudge(for: routine)
            }
        }
    }

    /// Cancel pending come-back nudges — e.g. when the app returns to the
    /// foreground and the routines are right there on screen again.
    func cancelInProgressNudges() {
        Task { @MainActor in
            let pending = await center.pendingNotificationRequests()
            let nudges = pending.map(\.identifier).filter { $0.hasPrefix("inprogress-") }
            center.removePendingNotificationRequests(withIdentifiers: nudges)
        }
    }

    /// One gentle nudge ~45 minutes after the app was left mid-routine —
    /// pressure-free, and it deep-links straight back into the routine.
    private func scheduleNudge(for routine: Routine) {
        let total = routine.sortedSteps.count
        let step = min(routine.currentStepIndex + 1, total)

        let content = UNMutableNotificationContent()
        content.title = "Partway there"
        content.body = "\u{201C}\(routine.title)\u{201D} — step \(step) of \(total) is waiting whenever you're ready."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["routineID": routine.uuid]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 45 * 60, repeats: false)
        center.add(UNNotificationRequest(
            identifier: Self.inProgressID(for: routine),
            content: content, trigger: trigger
        ))
    }

    /// Kaya only ever schedules routine reminders — clearing all is safe.
    func clearAll() {
        center.removeAllPendingNotificationRequests()
    }

    #if DEBUG
    /// Verification helper — lists what's actually queued.
    func pendingDebug() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }
    #endif

    private func schedule(for routine: Routine) {
        // Finished routines stay quiet — restart re-arms via syncAll/sync.
        guard routine.isScheduled, !routine.isFinished,
              let trigger = trigger(for: routine) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ready when you are"
        content.body = "\u{201C}\(routine.title)\u{201D} is planned for now — take it at your own pace."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["routineID": routine.uuid]

        center.add(UNNotificationRequest(
            identifier: routine.uuid, content: content, trigger: trigger
        ))
    }

    private func trigger(for routine: Routine) -> UNNotificationTrigger? {
        guard let minutes = routine.scheduledMinutes else { return nil }
        let calendar = Calendar.current
        var comps = DateComponents(hour: minutes / 60, minute: minutes % 60)

        switch routine.repeatRule {
        case .daily:
            return UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        case .weekly:
            comps.weekday = routine.scheduledWeekday
                ?? routine.scheduledDate.map { calendar.component(.weekday, from: $0) }
            guard comps.weekday != nil else { return nil }
            return UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        case .none:
            guard let day = routine.scheduledDate else { return nil }
            let dayComps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.year = dayComps.year
            comps.month = dayComps.month
            comps.day = dayComps.day
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            return trigger.nextTriggerDate() != nil ? trigger : nil
        }
    }
}
