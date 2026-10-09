//
//  RoutinesView.swift
//  Kaya
//
//  The Routines tab: continue card, saved routines, ready-made
//  templates, and the create button — all browsable by touch.
//

import SwiftData
import SwiftUI

struct RoutinesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Routine.lastActivityAt, order: .reverse) private var routines: [Routine]

    @State private var activeRoutine: Routine?
    @State private var showDeleteAllConfirm = false
    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()

    private var inProgressRoutine: Routine? {
        routines.first { $0.hasStarted && !$0.isFinished }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let routine = inProgressRoutine {
                        continueCard(routine)
                    }

                    todaySection

                    calendarSection

                    savedRoutinesSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(KayaTheme.background.ignoresSafeArea())
            .navigationTitle("Routines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label("Delete all saved routines", systemImage: "trash")
                        }
                        .disabled(routines.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(KayaTheme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("More options")
                }
            }
            .navigationDestination(for: RoutineDraft.self) { draft in
                RoutineReviewView(draft: draft)
            }
            .confirmationDialog(
                "Delete all saved routines?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    for routine in routines {
                        ReminderService.shared.cancelReminders(for: routine)
                        modelContext.delete(routine)
                    }
                    try? modelContext.save()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your routines and progress from this device. It cannot be undone.")
            }
            .fullScreenCover(item: $activeRoutine) { routine in
                GuidedTaskView(routine: routine)
            }
            // A reminder's "Start now" lands here via AppNavigation. TabView
            // children are lazy, so a request can arrive before this view
            // exists — check on appear too, not just on change.
            .onAppear { openRequestedRoutine() }
            .onChange(of: AppNavigation.shared.routineRequestID) { _, _ in openRequestedRoutine() }
            .onChange(of: routines.count) { _, _ in openRequestedRoutine() }
        }
    }

    /// Opens the routine a notification asked for. Only consumes the
    /// request once the routine is actually found — on this tab's first
    /// appearance the @Query may not have loaded yet.
    private func openRequestedRoutine() {
        guard let id = AppNavigation.shared.routineRequestID else { return }
        guard let routine = routines.first(where: { $0.uuid == id }) else { return }
        AppNavigation.shared.routineRequestID = nil
        if routine.isFinished { RoutineStore.restart(routine, in: modelContext) }
        activeRoutine = routine
    }

    // MARK: - Sections

    /// Shared eyebrow label for section headers — quiet caps, modern look.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .tracking(1.2)
            .foregroundStyle(KayaTheme.subtleText)
            .padding(.leading, 4)
    }

    /// Hero card for the routine in progress — ring showing how far along,
    /// a real "Resume" pill instead of a bare chevron.
    private func continueCard(_ routine: Routine) -> some View {
        let total = routine.sortedSteps.count
        return Button {
            activeRoutine = routine
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    KayaProgressRing(
                        value: total > 0 ? Double(routine.completedCount) / Double(total) : 0,
                        size: 46, lineWidth: 4
                    )
                    Image(systemName: "play.fill")
                        .font(.callout)
                        .foregroundStyle(KayaTheme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("CONTINUE")
                        .font(.caption2.bold())
                        .tracking(1)
                        .foregroundStyle(KayaTheme.accent)
                    Text(routine.title)
                        .font(.headline)
                        .foregroundStyle(KayaTheme.text)
                    Text("Step \(min(routine.currentStepIndex + 1, total)) of \(total)")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                }
                Spacer()
                Text("Resume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KayaTheme.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(KayaTheme.accent))
            }
            .kayaCard()
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(KayaTheme.accent.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Resumes your routine in progress")
    }

    @ViewBuilder
    private var savedRoutinesSection: some View {
        if routines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.title2)
                    .foregroundStyle(KayaTheme.accent)
                Text("No routines yet")
                    .font(.headline)
                    .foregroundStyle(KayaTheme.text)
                Text("Say a goal to Kaya, or write one by hand.")
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.subtleText)
                    .multilineTextAlignment(.center)
                NavigationLink {
                    RoutineBuilderView()
                } label: {
                    Text("Write a routine")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KayaTheme.accent)
                        .frame(minHeight: 40)
                }
            }
            .frame(maxWidth: .infinity)
            .kayaCard()
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Your routines")

                ForEach(routines) { routine in
                    savedRoutineRow(routine)
                }
            }
        }
    }

    private func savedRoutineRow(_ routine: Routine) -> some View {
        Button {
            activeRoutine = routine
        } label: {
            HStack(spacing: 14) {
                KayaIconTile(
                    symbol: routine.iconSymbol,
                    tint: routine.isFinished ? KayaTheme.success : KayaTheme.accent
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(routine.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KayaTheme.text)
                    HStack(spacing: 6) {
                        statusChip(for: routine)
                        if routine.isScheduled {
                            Label(routine.scheduleLabel, systemImage: "calendar")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(KayaTheme.subtleText)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if routine.hasStarted, !routine.isFinished, !routine.sortedSteps.isEmpty {
                    Text("\(routine.completedCount)/\(routine.sortedSteps.count)")
                        .font(.caption.bold())
                        .monospacedDigit()
                        .foregroundStyle(KayaTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(KayaTheme.warm))
                        .accessibilityLabel("\(routine.completedCount) of \(routine.sortedSteps.count) steps done")
                }
                if let data = routine.photoData.first, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KayaTheme.subtleText.opacity(0.6))
            }
            .kayaCard(padding: 14)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                RoutineStore.restart(routine, in: modelContext)
                activeRoutine = routine
            } label: {
                Label("Start again", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) {
                ReminderService.shared.cancelReminders(for: routine)
                modelContext.delete(routine)
                try? modelContext.save()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityHint("Opens this routine")
    }

    /// A colored state chip: done = green check, in progress = step count,
    /// fresh = "Ready". Difficulty rides along when it's known.
    private func statusChip(for routine: Routine) -> some View {
        HStack(spacing: 4) {
            if routine.isFinished {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(KayaTheme.success)
            } else if routine.hasStarted {
                Text("\(routine.completedCount) of \(routine.sortedSteps.count) done")
                    .foregroundStyle(KayaTheme.accent)
            } else {
                Text("Ready")
                    .foregroundStyle(KayaTheme.subtleText)
            }
            if let difficulty = routine.difficulty {
                Text("· felt \(difficulty.label.lowercased())")
                    .foregroundStyle(KayaTheme.subtleText)
            }
        }
        .font(.caption.weight(.medium))
    }

    /// What's due today — the daily landing spot. Finished ones show a
    /// quiet check instead of a start hint.
    @ViewBuilder
    private var todaySection: some View {
        let due = routinesOn(Date())
        if !due.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Today")

                ForEach(due) { routine in
                    savedRoutineRow(routine)
                }
            }
        }
    }

    // MARK: - Calendar

    /// A compact month grid. Days with scheduled routines get an orange
    /// dot; tapping a day shows what's planned for it below the grid.
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Calendar")
                Spacer()
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 32, minHeight: 32)
                        .background(Circle().fill(KayaTheme.warm.opacity(0.5)))
                }
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KayaTheme.text)
                    .frame(minWidth: 110)
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 32, minHeight: 32)
                        .background(Circle().fill(KayaTheme.warm.opacity(0.5)))
                }
            }
            .foregroundStyle(KayaTheme.accent)

            let calendar = Calendar.current
            let symbols = calendar.veryShortStandaloneWeekdaySymbols
            let start = calendar.firstWeekday - 1
            let weekdayLetters = Array(symbols[start...]) + Array(symbols[..<start])

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(.caption2.bold())
                        .foregroundStyle(KayaTheme.subtleText)
                        .frame(height: 22)
                }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, calendar: calendar)
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }
            .kayaCard()

            let planned = routinesOn(selectedDate)
            Text(selectedDate.formatted(date: .abbreviated, time: .omitted)
                 + (planned.isEmpty ? " — nothing planned" : ""))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KayaTheme.subtleText)
            ForEach(planned) { routine in
                savedRoutineRow(routine)
            }
        }
    }

    private func dayCell(_ date: Date, calendar: Calendar) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let hasRoutine = routines.contains { $0.occurs(on: date, in: calendar) }
        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? KayaTheme.onAccent
                                     : isToday ? KayaTheme.accent : KayaTheme.text)
                    .frame(width: 30, height: 26)
                    .background(isSelected ? KayaTheme.accent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // Today gets a quiet ring even when it isn't selected.
                    .overlay {
                        if isToday && !isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(KayaTheme.accent.opacity(0.45), lineWidth: 1)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isSelected)
                Circle()
                    .fill(hasRoutine ? KayaTheme.accent : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted)
            + (hasRoutine ? ", has a routine" : ""))
    }

    /// Cells for the displayed month — leading nils pad to the weekday.
    private var monthDays: [Date?] {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let first = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset)
            + range.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    private func routinesOn(_ date: Date) -> [Routine] {
        routines.filter { $0.occurs(on: date) }
    }

    private func shiftMonth(_ delta: Int) {
        displayedMonth = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
    }

}
