//
//  RoutineModels.swift
//  Kaya
//
//  SwiftData models, editable drafts, and built-in routine templates.
//

import Foundation
import SwiftData
import UIKit

// MARK: - Persisted models

@Model
final class Routine {
    /// Stable string ID — the notification identifier, so a reminder can
    /// deep-link back to this exact routine.
    var uuid: String = UUID().uuidString
    var title: String
    var goal: String
    var createdAt: Date
    var lastActivityAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var currentStepIndex: Int
    var isFinished: Bool
    var wasGeneratedByAI: Bool
    var speakInstructions: Bool
    var useSimpleInstructions: Bool
    var languageCode: String
    var deadline: Date?
    var difficultyRaw: String?
    var aiReflection: String?
    var photoData: [Data] = []
    /// Optional captions for `photoData` — feeds the AI reflection.
    var photoCaptions: [String] = []
    /// The last finished run had at least one skipped step — captured before
    /// `restart` clears the per-step flags, so Kaya can adapt next time.
    var lastRunHadSkips: Bool = false
    /// The gentler-version offer was already shown for the current outcome —
    /// set once so the banner never nags twice for the same run.
    var gentlerOffered: Bool = false
    /// The user's own words about how the last run went, AI-distilled.
    /// Fed back into gentlerVariant and the weekly summary.
    var lastUserNote: String?

    // Scheduling — set conversationally at creation, shown on the calendar.
    var repeatRuleRaw: String = RepeatRule.none.rawValue
    var scheduledWeekday: Int?    // 1–7 (Calendar weekday) for weekly repeats
    var scheduledDate: Date?      // anchor day for one-off plans
    var scheduledMinutes: Int?    // minutes from midnight, nil = any time

    @Relationship(deleteRule: .cascade, inverse: \RoutineStepRecord.routine)
    var steps: [RoutineStepRecord] = []

    init(
        title: String,
        goal: String = "",
        wasGeneratedByAI: Bool = false,
        speakInstructions: Bool = false,
        useSimpleInstructions: Bool = true,
        languageCode: String = "en"
    ) {
        self.title = title
        self.goal = goal
        self.createdAt = Date()
        self.lastActivityAt = Date()
        self.finishedAt = nil
        self.currentStepIndex = 0
        self.isFinished = false
        self.wasGeneratedByAI = wasGeneratedByAI
        self.speakInstructions = speakInstructions
        self.useSimpleInstructions = useSimpleInstructions
        self.languageCode = languageCode
        self.deadline = nil
        self.difficultyRaw = nil
        self.aiReflection = nil
        self.photoData = []
    }

    var difficulty: DifficultyLevel? {
        get { difficultyRaw.flatMap { DifficultyLevel(rawValue: $0) } }
        set { difficultyRaw = newValue?.rawValue }
    }

    var sortedSteps: [RoutineStepRecord] {
        steps.sorted { $0.order < $1.order }
    }

    /// A symbol that represents the routine — its first step's icon.
    var iconSymbol: String {
        sortedSteps.first?.displaySymbol ?? "list.bullet"
    }

    var completedCount: Int {
        steps.filter(\.isDone).count
    }

    var hasStarted: Bool {
        startedAt != nil || currentStepIndex > 0 || completedCount > 0
    }

    var repeatRule: RepeatRule {
        get { RepeatRule(rawValue: repeatRuleRaw) ?? .none }
        set { repeatRuleRaw = newValue.rawValue }
    }

    var isScheduled: Bool {
        repeatRule != .none || scheduledDate != nil || scheduledMinutes != nil
    }

    /// Does this routine belong on the calendar for a given day?
    func occurs(on date: Date, in calendar: Calendar = .current) -> Bool {
        switch repeatRule {
        case .daily:
            return true
        case .weekly:
            let weekday = scheduledWeekday
                ?? scheduledDate.map { calendar.component(.weekday, from: $0) }
            return weekday == calendar.component(.weekday, from: date)
        case .none:
            guard let scheduledDate else { return false }
            return calendar.isDate(scheduledDate, inSameDayAs: date)
        }
    }

    /// Short human description: "Every day · 8:00 AM", "Mondays", "Fri, 8:00 AM".
    var scheduleLabel: String {
        KayaSchedule.describe(repeatRule: repeatRule, weekday: scheduledWeekday,
                              date: scheduledDate, minutes: scheduledMinutes)
    }
}

/// How often a routine comes back.
enum RepeatRule: String, CaseIterable {
    case none, daily, weekly

    var label: String {
        switch self {
        case .none: return "Just once"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        }
    }
}

/// Shared helpers for describing and computing schedules.
enum KayaSchedule {
    static let weekdaySymbols = Calendar.current.weekdaySymbols // ["Sunday",…]

    static func describe(repeatRule: RepeatRule, weekday: Int?,
                         date: Date?, minutes: Int?) -> String {
        var parts: [String] = []
        switch repeatRule {
        case .daily:
            parts.append("Every day")
        case .weekly:
            if let weekday, (1...7).contains(weekday) {
                parts.append("Every \(weekdaySymbols[weekday - 1])")
            } else {
                parts.append("Every week")
            }
        case .none:
            if let date {
                parts.append(date.formatted(date: .abbreviated, time: .omitted))
            }
        }
        if let minutes {
            parts.append(timeString(minutes))
        }
        return parts.isEmpty ? "Not scheduled" : parts.joined(separator: " · ")
    }

    static func timeString(_ minutesFromMidnight: Int) -> String {
        var comps = DateComponents()
        comps.hour = minutesFromMidnight / 60
        comps.minute = minutesFromMidnight % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The next date falling on a Calendar weekday (1 = Sunday), today included.
    static func nextDate(weekday: Int, from start: Date = Date(),
                         in calendar: Calendar = .current) -> Date {
        var candidate = calendar.startOfDay(for: start)
        for _ in 0..<8 {
            if calendar.component(.weekday, from: candidate) == weekday { return candidate }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}

/// How a finished routine felt — feeds the AI's reflection message.
enum DifficultyLevel: String, CaseIterable {
    case easy, okay, hard

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .okay: return "Okay"
        case .hard: return "Hard"
        }
    }

    var symbol: String {
        switch self {
        case .easy: return "leaf.fill"
        case .okay: return "circle.dotted"
        case .hard: return "mountain.2.fill"
        }
    }
}

/// How small each generated step should be — "how much can I do at once".
enum StepSizePreference: String, CaseIterable {
    case tiny, regular, few

    var label: String {
        switch self {
        case .tiny: return "Very small steps"
        case .regular: return "Regular steps"
        case .few: return "Fewer, bigger steps"
        }
    }

    var detail: String {
        switch self {
        case .tiny: return "Break everything down — one tiny action at a time."
        case .regular: return "One clear action per step."
        case .few: return "Combine small actions into fewer steps."
        }
    }
}

/// How much encouragement the user wants from Kaya.
enum EncouragementLevel: String, CaseIterable {
    case quiet, some, lots

    var label: String {
        switch self {
        case .quiet: return "Keep it quiet"
        case .some: return "A little"
        case .lots: return "Cheer me on"
        }
    }
}

/// Personal context gathered at onboarding. Feeds the local AI so generated
/// routines fit the user — never leaves the device.
@Model
final class UserProfile {
    var name: String
    var prefersShortSteps: Bool
    var wantsSpokenInstructions: Bool
    var wantsVoiceControl: Bool
    var encouragementRaw: String
    var stepSizeRaw: String = StepSizePreference.regular.rawValue
    var extraContext: String
    var commonGoalsText: String = ""
    var hardThingsText: String = ""
    var helpfulThingsText: String = ""
    /// AI-distilled summary of the user's context — regenerated when answers
    /// change, keeps every prompt short for the on-device model.
    var aiContextSummary: String = ""
    /// Durable facts the user chose to let Kaya remember from conversation
    /// ("I work night shifts", "loud sounds are hard"). User-confirmed and
    /// user-deletable — Kaya never saves these silently.
    var learnedFacts: [String] = []
    var createdAt: Date

    // Progress stats for milestones.
    var routinesFinished: Int
    var stepsFinished: Int
    var usedVoiceControl: Bool
    var reflectionsGiven: Int = 0
    var photosAdded: Int = 0
    var finishDates: [Date]
    /// One entry per day the user completed at least one step — the raw
    /// material for "days in a row". Deduped by calendar day.
    var activeDays: [Date] = []
    var earnedMilestoneIDs: [String]

    init(name: String, prefersShortSteps: Bool, wantsSpokenInstructions: Bool,
         wantsVoiceControl: Bool, encouragement: EncouragementLevel, extraContext: String,
         stepSize: StepSizePreference = .regular, commonGoals: String = "",
         hardThings: String = "", helpfulThings: String = "") {
        self.name = name
        self.prefersShortSteps = prefersShortSteps
        self.wantsSpokenInstructions = wantsSpokenInstructions
        self.wantsVoiceControl = wantsVoiceControl
        self.encouragementRaw = encouragement.rawValue
        self.stepSizeRaw = stepSize.rawValue
        self.extraContext = extraContext
        self.commonGoalsText = commonGoals
        self.hardThingsText = hardThings
        self.helpfulThingsText = helpfulThings
        self.createdAt = Date()
        self.routinesFinished = 0
        self.stepsFinished = 0
        self.usedVoiceControl = false
        self.reflectionsGiven = 0
        self.photosAdded = 0
        self.finishDates = []
        self.earnedMilestoneIDs = []
    }

    var encouragement: EncouragementLevel {
        EncouragementLevel(rawValue: encouragementRaw) ?? .some
    }

    var stepSize: StepSizePreference {
        StepSizePreference(rawValue: stepSizeRaw) ?? .regular
    }

    var routinesFinishedThisWeek: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return finishDates.filter { $0 >= weekAgo }.count
    }

    /// Marks today as a day the user showed up — one step is enough.
    func noteActiveToday(in calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: Date())
        if !activeDays.contains(where: { calendar.isDate($0, inSameDayAs: today) }) {
            activeDays.append(today)
        }
    }
}

@Model
final class RoutineStepRecord {
    var title: String
    var instruction: String
    var doneDescription: String
    var symbolName: String
    var order: Int
    var isDone: Bool
    var estimatedMinutes: Int
    /// True when the user moved past this step without completing it —
    /// skipped steps are never counted as done, only remembered honestly.
    var skipped: Bool = false
    /// How long the step actually took the last time, in seconds.
    var lastDurationSeconds: Int? = nil
    var routine: Routine?

    init(
        title: String,
        instruction: String,
        doneDescription: String,
        symbolName: String,
        order: Int,
        estimatedMinutes: Int = 0
    ) {
        self.title = title
        self.instruction = instruction
        self.doneDescription = doneDescription
        self.symbolName = symbolName
        self.order = order
        self.isDone = false
        self.estimatedMinutes = estimatedMinutes
    }

    var displaySymbol: String {
        UIImage(systemName: symbolName) != nil ? symbolName : "checkmark.circle"
    }
}

// MARK: - Editable drafts (not persisted until the user starts the routine)

struct StepDraft: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var instruction: String
    var doneDescription: String
    var symbolName: String
    var estimatedMinutes: Int = 0
}

struct RoutineDraft: Hashable {
    var title: String
    var goal: String
    var steps: [StepDraft]
    var generatedByAI: Bool
    var speakInstructions: Bool
    var useSimpleInstructions: Bool
    var languageCode: String
    var deadline: Date?

    // Schedule — answered conversationally after generation.
    var repeatRule: RepeatRule = .none
    var scheduledWeekday: Int? = nil
    var scheduledDate: Date? = nil
    var scheduledMinutes: Int? = nil

    init(
        title: String,
        goal: String = "",
        steps: [StepDraft],
        generatedByAI: Bool = false,
        speakInstructions: Bool = false,
        useSimpleInstructions: Bool = true,
        languageCode: String = "en",
        deadline: Date? = nil
    ) {
        self.title = title
        self.goal = goal
        self.steps = steps
        self.generatedByAI = generatedByAI
        self.speakInstructions = speakInstructions
        self.useSimpleInstructions = useSimpleInstructions
        self.languageCode = languageCode
        self.deadline = deadline
    }

    static var blank: RoutineDraft {
        RoutineDraft(
            title: "",
            steps: [
                StepDraft(title: "", instruction: "", doneDescription: "", symbolName: "checkmark.circle")
            ]
        )
    }
}
