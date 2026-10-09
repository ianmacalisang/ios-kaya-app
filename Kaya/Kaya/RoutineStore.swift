//
//  RoutineStore.swift
//  Kaya
//
//  Built-in routine templates and persistence helpers.
//

import Foundation
import SwiftData
import UserNotifications

enum RoutineStore {

    // MARK: - Built-in templates (always work without AI)

    static let templates: [RoutineDraft] = [
        RoutineDraft(
            title: "Get ready for school or work",
            steps: [
                StepDraft(title: "Get dressed", instruction: "Put on your clothes for the day.", doneDescription: "You are fully dressed.", symbolName: "tshirt.fill", estimatedMinutes: 5),
                StepDraft(title: "Eat breakfast", instruction: "Eat something and drink some water.", doneDescription: "You have eaten and had a drink.", symbolName: "fork.knife", estimatedMinutes: 10),
                StepDraft(title: "Brush your teeth", instruction: "Brush your teeth for about two minutes.", doneDescription: "Your teeth are brushed.", symbolName: "sparkles", estimatedMinutes: 3),
                StepDraft(title: "Pack your bag", instruction: "Put everything you need in your bag.", doneDescription: "Your bag is packed and closed.", symbolName: "backpack.fill", estimatedMinutes: 4),
                StepDraft(title: "Check your essentials", instruction: "Make sure you have your phone, keys, and wallet.", doneDescription: "You have your phone, keys, and wallet.", symbolName: "key.fill", estimatedMinutes: 1),
                StepDraft(title: "Leave home", instruction: "Put on your shoes and go out the door.", doneDescription: "You are outside with the door closed.", symbolName: "figure.walk", estimatedMinutes: 2)
            ]
        ),
        RoutineDraft(
            title: "Go to the grocery store",
            steps: [
                StepDraft(title: "Make a list", instruction: "Write down what you need to buy.", doneDescription: "Your shopping list is ready.", symbolName: "list.bullet", estimatedMinutes: 5),
                StepDraft(title: "Bring what you need", instruction: "Take your list, bag, and a way to pay.", doneDescription: "You have your list, bag, and payment.", symbolName: "bag.fill", estimatedMinutes: 2),
                StepDraft(title: "Go to the store", instruction: "Travel to the grocery store.", doneDescription: "You have arrived at the store.", symbolName: "figure.walk", estimatedMinutes: 15),
                StepDraft(title: "Find your items", instruction: "Go through your list and put each item in your basket.", doneDescription: "Every item on your list is in your basket.", symbolName: "cart.fill", estimatedMinutes: 15),
                StepDraft(title: "Pay", instruction: "Go to the checkout and pay for your items.", doneDescription: "You have paid and have your receipt.", symbolName: "creditcard.fill", estimatedMinutes: 5),
                StepDraft(title: "Go home", instruction: "Bring your groceries home.", doneDescription: "You are home with your groceries.", symbolName: "house.fill", estimatedMinutes: 15),
                StepDraft(title: "Put food away", instruction: "Put the groceries where they belong.", doneDescription: "All the groceries are put away.", symbolName: "checkmark.circle", estimatedMinutes: 5)
            ]
        ),
        RoutineDraft(
            title: "Get ready to leave home",
            steps: [
                StepDraft(title: "Check the weather", instruction: "Look outside or check a weather app.", doneDescription: "You know what the weather is like.", symbolName: "cloud.sun.fill", estimatedMinutes: 1),
                StepDraft(title: "Get dressed", instruction: "Put on clothes that fit the weather.", doneDescription: "You are dressed and ready.", symbolName: "tshirt.fill", estimatedMinutes: 5),
                StepDraft(title: "Gather your things", instruction: "Collect your phone, keys, wallet, and anything else you need.", doneDescription: "Everything you need is in one place.", symbolName: "bag.fill", estimatedMinutes: 3),
                StepDraft(title: "Check the home", instruction: "Switch off lights and things you will not use.", doneDescription: "Lights and unused things are off.", symbolName: "lightbulb.fill", estimatedMinutes: 2),
                StepDraft(title: "Lock the door", instruction: "Close and lock the door behind you.", doneDescription: "The door is locked.", symbolName: "lock.fill", estimatedMinutes: 1),
                StepDraft(title: "You are ready", instruction: "You can go at your own pace now.", doneDescription: "You have left home.", symbolName: "checkmark.circle.fill", estimatedMinutes: 1)
            ]
        )
    ]

    static let suggestedGoals: [String] = [
        "Get ready for school",
        "Pack my bag",
        "Buy groceries",
        "Order food",
        "Get ready for an appointment"
    ]

    // MARK: - Persistence helpers

    @discardableResult
    static func save(_ draft: RoutineDraft, in context: ModelContext) -> Routine {
        let routine = Routine(
            title: draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? "My routine" : draft.title,
            goal: draft.goal,
            wasGeneratedByAI: draft.generatedByAI,
            speakInstructions: draft.speakInstructions,
            useSimpleInstructions: draft.useSimpleInstructions,
            languageCode: draft.languageCode
        )
        routine.deadline = draft.deadline
        routine.repeatRule = draft.repeatRule
        routine.scheduledWeekday = draft.scheduledWeekday
        routine.scheduledDate = draft.scheduledDate
        routine.scheduledMinutes = draft.scheduledMinutes
        context.insert(routine)
        for (index, step) in draft.steps.enumerated() {
            guard !step.title.trimmingCharacters(in: .whitespaces).isEmpty
                    || !step.instruction.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let record = RoutineStepRecord(
                title: step.title.isEmpty ? "Step \(index + 1)" : step.title,
                instruction: step.instruction,
                doneDescription: step.doneDescription,
                symbolName: step.symbolName,
                order: index,
                estimatedMinutes: step.estimatedMinutes
            )
            routine.steps.append(record)
        }
        try? context.save()
        // First routine saved with a clock time — one-time iOS opt-in.
        // Ask first, then sync: sync() skips while authorization is still
        // notDetermined, so syncing before the grant loses this reminder.
        if routine.isScheduled, routine.scheduledMinutes != nil,
           ReminderService.shared.authorization == .notDetermined {
            Task {
                await ReminderService.shared.requestPermission()
                ReminderService.shared.sync(routine)
            }
        } else {
            ReminderService.shared.sync(routine)
        }
        return routine
    }

    static func restart(_ routine: Routine, in context: ModelContext) {
        for step in routine.steps {
            step.isDone = false
            step.skipped = false
            step.lastDurationSeconds = nil
        }
        routine.currentStepIndex = 0
        routine.isFinished = false
        routine.startedAt = nil
        routine.finishedAt = nil
        routine.lastActivityAt = Date()
        try? context.save()
        // Re-arm the reminder — the routine is back on the calendar.
        ReminderService.shared.sync(routine)
    }

    /// A finished repeat routine isn't finished forever — "every day"
    /// means it comes back tomorrow. When a new occurrence day arrives
    /// after the finish day, reopen the routine so it's due again.
    /// Completion history (reflections, photos, finishDates) stays put.
    static func refreshRepeating(_ routines: [Routine], in context: ModelContext) {
        let today = Date()
        for routine in routines where routine.isFinished && routine.repeatRule != .none {
            guard routine.occurs(on: today) else { continue }
            if let finishedAt = routine.finishedAt,
               Calendar.current.isDate(finishedAt, inSameDayAs: today) {
                continue
            }
            restart(routine, in: context)
        }
    }

    static func touch(_ routine: Routine, in context: ModelContext) {
        routine.lastActivityAt = Date()
        try? context.save()
    }
}
