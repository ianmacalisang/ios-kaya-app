//
//  ContentView.swift
//  Kaya
//
//  Root of the app: a bottom navigation dock with four tabs —
//  Kaya (voice home), Routines, Progress, and You.
//  Shows onboarding until a profile exists.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]
    @Query private var routines: [Routine]
    @State private var showOnboarding = false
    @State private var checkedProfile = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Kaya", systemImage: "waveform", value: 0) {
                HomeView(selectedTab: $selectedTab)
            }
            Tab("Routines", systemImage: "checklist", value: 1) {
                RoutinesView()
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: 2) {
                ProgressTabView()
            }
            Tab("You", systemImage: "person.crop.circle", value: 3) {
                AboutYouView()
            }
        }
        .tint(KayaTheme.accent)
        .onAppear {
            #if DEBUG
            if let tabEnv = ProcessInfo.processInfo.environment["KAYA_TAB"],
               let tab = Int(tabEnv) {
                selectedTab = tab
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.environment["KAYA_DEMO_SCREEN"] != nil,
               profiles.isEmpty {
                let seeded = UserProfile(
                    name: "Alex", prefersShortSteps: true, wantsSpokenInstructions: false,
                    wantsVoiceControl: true, encouragement: .some, extraContext: ""
                )
                seeded.routinesFinished = 3
                seeded.stepsFinished = 12
                seeded.finishDates = [Date()]
                let cal = Calendar.current
                seeded.activeDays = (0..<4).compactMap {
                    cal.date(byAdding: .day, value: -$0, to: Date())
                } + [7, 9, 12, 15, 20].compactMap {
                    cal.date(byAdding: .day, value: -$0, to: Date())
                }
                modelContext.insert(seeded)
                let profile = seeded
                newMilestoneSeeding(profile)
                try? modelContext.save()
            }
            #endif
            if !checkedProfile {
                checkedProfile = true
                showOnboarding = profiles.isEmpty
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["KAYA_DEMO_SCREEN"] == "reminder" {
                Task {
                    _ = await ReminderService.shared.requestPermission()
                    var draft = RoutineStore.templates[0]
                    draft.repeatRule = .daily
                    let soon = Date().addingTimeInterval(90)
                    draft.scheduledMinutes = Calendar.current.component(.hour, from: soon) * 60
                        + Calendar.current.component(.minute, from: soon)
                    let routine = RoutineStore.save(draft, in: modelContext)
                    let pending = await ReminderService.shared.pendingDebug()
                    NSLog("KAYA-REMINDER scheduled=%@ pending=%d",
                          routine.uuid, pending.count)
                }
            }
            #endif
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .task { ReminderService.shared.syncAll(routines) }
        // Leaving the app mid-routine arms a gentle "step N is waiting"
        // nudge; coming back cancels it — the routine is already on screen.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                ReminderService.shared.syncInProgress(routines)
            case .active:
                ReminderService.shared.cancelInProgressNudges()
            default:
                break
            }
        }
        // A reminder was tapped — jump to Routines; RoutinesView opens it.
        .onChange(of: AppNavigation.shared.routineRequestID) { _, id in
            if id != nil { selectedTab = 1 }
        }
    }

    #if DEBUG
    private func newMilestoneSeeding(_ profile: UserProfile) {
        _ = Momentum.checkNew(in: profile)
    }
    #endif
}
