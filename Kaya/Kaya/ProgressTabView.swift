//
//  ProgressTabView.swift
//  Kaya
//
//  The Progress tab: gentle milestones, stats, and finished
//  routines with their reflections and photo memories.
//

import SwiftData
import SwiftUI

struct ProgressTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @Query(sort: \Routine.lastActivityAt, order: .reverse) private var routines: [Routine]

    @State private var activeRoutine: Routine?
    @State private var aiService = LocalAIService()
    @State private var weeklyNote: String?
    @State private var weeklyLoading = false

    private var profile: UserProfile? { profiles.first }

    private var finishedRoutines: [Routine] {
        routines.filter(\.isFinished)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    aiNoteCard

                    if let profile {
                        momentumCard(profile)
                    }

                    if !finishedRoutines.isEmpty {
                        finishedSection
                    }

                    if profile == nil && finishedRoutines.isEmpty {
                        ContentUnavailableView(
                            "Nothing yet",
                            systemImage: "star",
                            description: Text("Finish a routine and your milestones will live here.")
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(KayaTheme.background.ignoresSafeArea())
            .navigationTitle("Your progress")
            .task { await loadWeeklyNote() }
            .onChange(of: profile?.routinesFinishedThisWeek ?? 0) { _, _ in
                Task { await loadWeeklyNote() }
            }
            .fullScreenCover(item: $activeRoutine) { routine in
                GuidedTaskView(routine: routine)
            }
        }
    }

    private func momentumCard(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    KayaProgressRing(
                        value: Momentum.levelProgress(for: profile.routinesFinished),
                        size: 76,
                        lineWidth: 7
                    )
                    Image(systemName: "star.fill")
                        .font(.title3)
                        .foregroundStyle(KayaTheme.accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(Momentum.levelName(for: profile.routinesFinished))
                        .font(.headline)
                        .foregroundStyle(KayaTheme.text)
                    Text("\(profile.routinesFinished) routines · \(profile.stepsFinished) steps done")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                    if let next = Momentum.nextLevel(for: profile.routinesFinished) {
                        Text("\(next.routinesLeft) more to reach “\(next.name)”")
                            .font(.caption)
                            .foregroundStyle(KayaTheme.accent)
                    }
                }
                Spacer()
            }

            weekDots(profile)

            streakRow(profile)

            monthStrip(profile)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Momentum.all) { milestone in
                        let earned = profile.earnedMilestoneIDs.contains(milestone.id)
                        VStack(spacing: 4) {
                            Image(systemName: milestone.symbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(earned ? KayaTheme.onAccent : KayaTheme.subtleText.opacity(0.6))
                                .frame(width: 44, height: 44)
                                .background {
                                    if earned {
                                        Circle().fill(
                                            LinearGradient(
                                                colors: [KayaTheme.accent, KayaTheme.accent.opacity(0.7)],
                                                startPoint: .top, endPoint: .bottom)
                                        )
                                    } else {
                                        Circle().stroke(KayaTheme.subtleText.opacity(0.3), lineWidth: 1.5)
                                    }
                                }
                            Text(milestone.title)
                                .font(.caption2)
                                .foregroundStyle(earned ? KayaTheme.text : KayaTheme.subtleText)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(milestone.title). \(earned ? "Earned" : "Not earned yet"). \(milestone.detail)")
                    }
                }
            }

            if let hint = Momentum.nextHint(for: profile) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }
        }
        .kayaCard()
        .accessibilityElement(children: .contain)
    }

    /// Kaya's on-device weekly note — sits at the top of Progress so the
    /// AI's read on the week is the first thing seen.
    @ViewBuilder
    private var aiNoteCard: some View {
        if weeklyLoading || weeklyNote != nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("Kaya on your week", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KayaTheme.accent)
                if weeklyLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(KayaTheme.accent).controlSize(.small)
                        Text("Thinking on this device…")
                            .font(.caption)
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                } else if let weeklyNote {
                    Text(weeklyNote)
                        .font(.callout)
                        .foregroundStyle(KayaTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kayaCard()
        }
    }

    /// Kaya's short weekly reflection — generated on-device, with a simple
    /// fallback when the model isn't available.
    private func loadWeeklyNote() async {
        guard let profile, profile.routinesFinished > 0 else { return }
        weeklyLoading = weeklyNote == nil
        let hardestRoutine = finishedRoutines.first(where: { $0.difficulty == .hard })
        if let note = try? await aiService.weeklySummary(
            finishedThisWeek: profile.routinesFinishedThisWeek,
            totalFinished: profile.routinesFinished,
            hardestTitle: hardestRoutine?.title,
            hardestNote: hardestRoutine?.lastUserNote,
            profile: profile
        ) {
            weeklyNote = note
        } else {
            weeklyNote = profile.routinesFinishedThisWeek > 0
                ? "\(profile.routinesFinishedThisWeek) routine\(profile.routinesFinishedThisWeek == 1 ? "" : "s") finished this week — all at your own pace."
                : "A quiet week — that's okay too. Your routines are ready whenever you are."
        }
        weeklyLoading = false
    }

    /// A dot per day for the last week — filled on days a routine finished.
    private func weekDots(_ profile: UserProfile) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return VStack(alignment: .leading, spacing: 6) {
            Text("This week")
                .font(.caption)
                .foregroundStyle(KayaTheme.subtleText)
            HStack(spacing: 12) {
                ForEach(0..<7, id: \.self) { offset in
                    let day = calendar.date(byAdding: .day, value: offset - 6, to: today) ?? today
                    let didFinish = profile.finishDates.contains {
                        calendar.isDate($0, inSameDayAs: day)
                    }
                    Circle()
                        .fill(didFinish ? KayaTheme.accent : KayaTheme.warm)
                        .frame(width: 12, height: 12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(profile.routinesFinishedThisWeek) routines finished this week")
        }
    }

    /// Days-in-a-row chip — celebrates the current run, and when it has
    /// paused shows the best run instead. Absence is never shown as a loss.
    @ViewBuilder
    private func streakRow(_ profile: UserProfile) -> some View {
        let run = Momentum.currentRun(in: profile.activeDays)
        let best = Momentum.longestRun(in: profile.activeDays)
        if run >= 2 {
            Label("\(run) days in a row", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(KayaTheme.warm.opacity(0.6)))
                .accessibilityLabel("You have shown up \(run) days in a row")
        } else if best >= 2 {
            Label("Best: \(best) days in a row", systemImage: "flame")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.subtleText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(KayaTheme.warm.opacity(0.35)))
                .accessibilityLabel("Your longest run is \(best) days in a row")
        }
    }

    /// A dot per day for the last four weeks — filled on days the user
    /// did at least one step. Quiet evidence of showing up.
    private func monthStrip(_ profile: UserProfile) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let active = Set(profile.activeDays.map { calendar.startOfDay(for: $0) })
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last 4 weeks")
                .font(.caption)
                .foregroundStyle(KayaTheme.subtleText)
            HStack(spacing: 5) {
                ForEach(0..<28, id: \.self) { offset in
                    let day = calendar.date(byAdding: .day, value: offset - 27, to: today) ?? today
                    Circle()
                        .fill(active.contains(day) ? KayaTheme.accent : KayaTheme.warm)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(active.count) days with activity in total")
        }
    }

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finished routines")
                .font(.title3.bold())
                .foregroundStyle(KayaTheme.text)

            ForEach(finishedRoutines) { routine in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(routine.title)
                            .font(.headline)
                            .foregroundStyle(KayaTheme.text)
                        Spacer()
                        if let difficulty = routine.difficulty {
                            Label(difficulty.label, systemImage: difficulty.symbol)
                                .font(.caption)
                                .foregroundStyle(KayaTheme.accent)
                        }
                    }
                    if let reflection = routine.aiReflection {
                        Text(reflection)
                            .font(.caption)
                            .foregroundStyle(KayaTheme.subtleText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !routine.photoData.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(routine.photoData.enumerated()), id: \.offset) { _, data in
                                if let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }

                    Button {
                        RoutineStore.restart(routine, in: modelContext)
                        activeRoutine = routine
                    } label: {
                        Label("Do it again", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(KayaTheme.accent)
                            .frame(minHeight: 40)
                    }
                    .accessibilityHint("Starts this routine over from the first step")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .kayaCard(padding: 16)
            }
        }
    }
}
