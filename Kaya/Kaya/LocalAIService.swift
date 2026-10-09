//
//  LocalAIService.swift
//  Kaya
//
//  On-device routine generation using Apple's Foundation Models framework.
//  No cloud calls — everything runs in SystemLanguageModel on device.
//

import Foundation
import FoundationModels
import UIKit

// MARK: - Guided generation output

@Generable(description: "A calm, step-by-step routine for an everyday goal.")
struct GeneratedRoutine {
    @Guide(description: "A short, friendly title for the routine, 2 to 6 words.")
    var title: String

    @Guide(description: "Between 3 and 8 concrete steps, in the order they should happen.")
    var steps: [GeneratedStep]
}

@Generable(description: "One step of a routine. One clear action only.")
struct GeneratedStep {
    @Guide(description: "A very short step name, 1 to 4 words.")
    var title: String

    @Guide(description: "One short instruction sentence in plain, literal language.")
    var instruction: String

    @Guide(description: "How the user knows this step is finished, a few words.")
    var doneDescription: String

    @Guide(description: "One common Apple SF Symbol name that fits the step, for example 'cart.fill', 'bag.fill', 'figure.walk', 'fork.knife', 'house.fill'.")
    var symbol: String

    @Guide(description: "A realistic estimate of how many minutes this step takes. A whole number.")
    var estimatedMinutes: Int
}

@Generable(description: "A small set of safe alternative actions for an unexpected situation.")
struct GeneratedSuggestions {
    @Guide(description: "2 or 3 short, safe, practical suggestions the user could try next. One short sentence each.")
    var options: [String]
}

/// Structured understanding of one thing the user said to Kaya.
@Generable(description: "What the user means in a conversation with Kaya, a routine-building assistant.")
struct ConversationIntent {
    @Guide(description: "One of: newGoal, openRoutine, start, showSteps, retry, edit, cancel, restart, answer, chat, progress, suggest. 'restart' = scrap this conversation and begin again ('start over', 'from scratch'). 'retry' = a different version of the same goal. 'edit' = revise the pending plan ('revise the plan', 'change step two', 'make it shorter'). 'answer' = replying to a question Kaya asked; 'newGoal' = a goal or task they want a routine for. 'chat' = small talk — greetings, feelings, jokes, or questions about Kaya herself. 'progress' = questions about the user's own results — 'how am I doing', 'did I finish X', 'what did I skip', 'what's left today', 'how many steps'. 'suggest' = asking Kaya what to do — 'what should I do now', 'suggest something', 'ano gagawin ko'.")
    var intent: String

    @Guide(description: "The goal or routine name if the user stated one, otherwise empty.")
    var subject: String

    @Guide(description: "If the user says how often it repeats: 'once', 'daily', or 'weekly'. Empty if not mentioned.")
    var repeatRule: String

    @Guide(description: "Weekday the user named, 1 = Sunday through 7 = Saturday. 0 if none.")
    var weekday: Int

    @Guide(description: "Time of day in minutes since midnight, e.g. 8:30 AM = 510. -1 if none.")
    var minutesFromMidnight: Int

    @Guide(description: "What Kaya should say back — one or two short, calm sentences. For 'chat' this is the actual conversational reply; for every other intent it just acknowledges what Kaya is doing.")
    var reply: String

    @Guide(description: "A durable fact the user shared about themselves — a preference, schedule, sensitivity, or circumstance that will still be true later — restated in a few words. Empty for temporary states like 'i'm tired', questions, or anything not about the user.")
    var learnedFact: String
}

@Generable(description: "A simpler version of a routine step.")
struct SimplifiedStep {
    @Guide(description: "The same instruction, rewritten plainer and shorter — under ten words if possible.")
    var simplerInstruction: String
}

@Generable(description: "A routine step broken into smaller actions.")
struct BrokenDownStep {
    @Guide(description: "2 or 3 smaller actions that together complete the step. One short sentence each, in order.")
    var microSteps: [String]
}

@Generable(description: "Things the user will need for a routine.")
struct ItemChecklist {
    @Guide(description: "2 to 5 concrete items the steps imply the user needs, e.g. 'keys', 'a jacket'. Empty if nothing is needed.")
    var items: [String]
}

// MARK: - Service

enum AIAvailability: Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady

    var message: String {
        switch self {
        case .available:
            return ""
        case .deviceNotEligible:
            return "On-device AI is not supported on this device. You can still use ready-made routines or write your own steps."
        case .appleIntelligenceOff:
            return "Apple Intelligence is turned off. Turn it on in Settings to generate steps with on-device AI, or write your own steps."
        case .modelNotReady:
            return "The on-device model is still getting ready. Try again in a moment, or write your own steps."
        }
    }
}

enum AIGenerationError: Error {
    case unavailable
    case emptyResult
}

final class LocalAIService {

    var availability: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            default: return .deviceNotEligible
            }
        }
    }

    private static let routineInstructions = """
        You are Kaya, a respectful everyday task assistant.
        Turn the user's chosen goal into 3 to 8 concrete, short, sequential steps.
        Use plain, literal language. Avoid unnecessary complexity, idioms, judgment, urgency, and infantilizing language.
        Do not assume the user's abilities, resources, environment, or preferences.
        Do not claim that a step is complete unless the user confirms it.
        If essential information is missing, use a clearly labeled, editable suggestion instead of inventing personal details.
        Do not provide unsafe instructions. For activities involving medication, hazardous equipment, or other high-risk tasks, avoid operational guidance and direct users to a trusted support person or appropriate professional.
        The user remains in control and can edit, skip, repeat, pause, or stop any step.

        Step quality rules:
        - Every step is ONE concrete physical action in the order a person would do it — never a vague state like "get ready" or "prepare".
        - If the task needs items, start with a step to gather them.
        - title: 2 to 4 words starting with a verb ("Pick up towel"). instruction: one short sentence saying exactly what to do. doneDescription: what the user can see or check to know it is done.
        - symbol: one SF Symbol name that literally matches the step.
        - estimatedMinutes: a realistic small number (usually 1 to 15).

        Example — goal "make a ham sandwich" produces steps like:
        1. title "Gather ingredients", instruction "Get the bread, ham, cheese, butter, a knife, and a plate.", doneDescription "Everything is on the counter.", symbol "basket", 2 minutes
        2. title "Butter the bread", instruction "Spread butter on both slices of bread.", doneDescription "Both slices are buttered.", symbol "fork.knife", 1 minute
        3. title "Build the sandwich", instruction "Put ham and cheese on one slice, then close it with the other.", doneDescription "The sandwich is assembled.", symbol "square.stack", 2 minutes
        4. title "Clean up", instruction "Put the knife in the sink and put the ingredients away.", doneDescription "The counter is clear.", symbol "sparkles", 2 minutes
        """

    /// One sentence joining everything the user told us about themselves —
    /// the saved context reference used by every AI call.
    private static func userContextSummary(_ profile: UserProfile?) -> String? {
        guard let profile else { return nil }
        if !profile.aiContextSummary.isEmpty {
            return profile.aiContextSummary
        }
        var parts: [String] = []
        if !profile.hardThingsText.isEmpty {
            parts.append("hard things: \(profile.hardThingsText)")
        }
        if !profile.helpfulThingsText.isEmpty {
            parts.append("what helps: \(profile.helpfulThingsText)")
        }
        if !profile.learnedFacts.isEmpty {
            parts.append("remembered: \(profile.learnedFacts.joined(separator: ", "))")
        }
        if !profile.extraContext.isEmpty {
            parts.append(profile.extraContext)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Instructions tuned by the user's onboarding profile — all local.
    private func personalizedInstructions(profile: UserProfile?, simpleSteps: Bool) -> String {
        var instructions = Self.routineInstructions
        guard let profile else { return instructions }

        if !profile.name.isEmpty {
            instructions += "\nThe user is called \(profile.name)."
        }
        if simpleSteps || profile.prefersShortSteps {
            instructions += "\nKeep each instruction extra short — ideally under ten words."
        }
        switch profile.stepSize {
        case .tiny:
            instructions += "\nBreak the goal into many very small steps — up to 8. Each step is a single tiny action."
        case .regular:
            break
        case .few:
            instructions += "\nUse fewer, bigger steps — 3 to 5 total. Combine small actions into one step."
        }
        switch profile.encouragement {
        case .quiet:
            instructions += "\nUse a neutral, minimal tone. No praise inside instructions."
        case .some:
            instructions += "\nUse a lightly warm tone."
        case .lots:
            instructions += "\nUse a warm, encouraging tone while staying calm and brief."
        }
        if !profile.commonGoalsText.isEmpty {
            instructions += "\nThe user often does: \(profile.commonGoalsText). When the goal relates to these, keep wording familiar and predictable."
        }
        if !profile.hardThingsText.isEmpty {
            instructions += "\nTasks are harder for this user when: \(profile.hardThingsText). Shape steps to soften or work around these."
        }
        if !profile.helpfulThingsText.isEmpty {
            instructions += "\nThings that help this user: \(profile.helpfulThingsText). Build them into steps when they fit naturally."
        }
        if !profile.extraContext.isEmpty {
            instructions += """

            \nThe user shared this about themselves: "\(profile.extraContext)".
            Respect it when writing steps. Do not invent personal details beyond it.
            """
        }
        return instructions
    }

    /// Generate a routine for a natural-language goal. Runs fully on device.
    func generateRoutine(
        goal: String,
        useSimpleInstructions: Bool,
        languageCode: String,
        profile: UserProfile? = nil,
        deadline: Date? = nil
    ) async throws -> RoutineDraft {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var prompt = "Goal: \(goal)\n"
        if useSimpleInstructions {
            prompt += "Use very simple sentences. One action per step.\n"
        }
        if let deadline {
            let minutesLeft = max(Int(deadline.timeIntervalSinceNow / 60), 0)
            let formatted = deadline.formatted(date: .abbreviated, time: .shortened)
            prompt += "The user wants to finish by \(formatted) — about \(minutesLeft) minutes from now. Keep the whole routine comfortably within that time, and estimate minutes for each step.\n"
        }

        let filipinoSupported = SystemLanguageModel.default.supportedLanguages
            .contains { $0.languageCode?.identifier == "fil" || $0.languageCode?.identifier == "tl" }
        if languageCode == "fil", filipinoSupported {
            prompt += "Write the steps in simple Filipino (Tagalog).\n"
        }

        let session = LanguageModelSession(
            instructions: personalizedInstructions(profile: profile, simpleSteps: useSimpleInstructions)
        )
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedRoutine.self,
            options: GenerationOptions(sampling: .greedy)
        )

        let generated = response.content
        guard !generated.steps.isEmpty else { throw AIGenerationError.emptyResult }

        // Lightly repair weak output — small models occasionally emit
        // empty fields or duplicate steps.
        var seenTitles = Set<String>()
        let drafts = generated.steps.prefix(8).compactMap { step -> StepDraft? in
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let done = step.doneDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seenTitles.insert(title.lowercased()).inserted else { return nil }
            return StepDraft(
                title: title,
                instruction: instruction.isEmpty ? title : instruction,
                doneDescription: done.isEmpty ? "The step is done." : done,
                symbolName: UIImage(systemName: step.symbol) != nil ? step.symbol : "checkmark.circle",
                estimatedMinutes: min(max(step.estimatedMinutes, 0), 90)
            )
        }
        guard drafts.count >= 2 else { throw AIGenerationError.emptyResult }

        return RoutineDraft(
            title: generated.title,
            goal: goal,
            steps: drafts,
            generatedByAI: true,
            speakInstructions: false,
            useSimpleInstructions: useSimpleInstructions,
            languageCode: languageCode,
            deadline: deadline
        )
    }

    /// A short, honest reflection after the user finishes a routine —
    /// praises the effort, never exaggerates ability. On-device only.
    func reflectOnCompletion(
        routineTitle: String,
        stepCount: Int,
        difficulty: DifficultyLevel?,
        photoCount: Int,
        photoCaptions: [String] = [],
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            The user just finished a routine. Write one or two short sentences
            acknowledging what they accomplished.
            Be warm, specific, and honest. Praise the effort, not imagined abilities.
            Never exaggerate. No emojis, no exclamation marks. Calm tone.
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name). You may use their name once."
        }
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context to keep in mind: \(context)"
        }
        instructions += "\nDo not ask questions. Do not offer further help."

        var prompt = "Routine: \(routineTitle)\nSteps completed: \(stepCount)\n"
        if let difficulty {
            prompt += "The user said it felt: \(difficulty.label.lowercased()).\n"
            if difficulty == .hard {
                prompt += "Recognize that finishing something hard took real effort.\n"
            }
        }
        if photoCount > 0 {
            prompt += "They saved \(photoCount) photo\(photoCount == 1 ? "" : "s") of their result.\n"
            let captions = photoCaptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !captions.isEmpty {
                prompt += "They described the photos as: \(captions.joined(separator: "; ")). You may reference this.\n"
            }
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// A calm one-line note on whether the estimated steps fit the deadline.
    /// No pressure, no urgency.
    func paceCheck(
        totalMinutes: Int,
        stepCount: Int,
        deadline: Date,
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        let minutesLeft = max(Int(deadline.timeIntervalSinceNow / 60), 0)
        let formatted = deadline.formatted(date: .omitted, time: .shortened)

        let instructions = """
            You are Kaya, a respectful everyday task assistant.
            The user set a soft finish-by time. In one short, calm sentence,
            say whether the estimated steps fit before that time.
            No urgency, no pressure, no warnings. If it is tight, suggest
            removing or simplifying a step as an option, not a rule.
            Do not ask questions. Do not offer further help.
            """

        var prompt = """
            Steps: \(stepCount)
            Estimated total: \(totalMinutes) minutes
            Time until the finish-by time (\(formatted)): about \(minutesLeft) minutes
            """
        if let name = profile?.name, !name.isEmpty {
            prompt += "\nThe user is called \(name)."
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// Suggest alternatives when something changed mid-routine. Fully on device.
    func suggestAlternatives(
        situation: String,
        stepTitle: String,
        routineTitle: String,
        profile: UserProfile? = nil
    ) async throws -> [String] {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            The user is doing a routine and something changed.
            Offer 2 or 3 short, safe, practical next actions. Use plain language.
            Do not assume it is an emergency. Do not guess the user's feelings.
            Never suggest unsafe actions. If the situation may be unsafe, suggest asking a trusted person.
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name)."
        }
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let prompt = """
            Routine: \(routineTitle)
            Current step: \(stepTitle)
            What changed: \(situation)
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedSuggestions.self,
            options: GenerationOptions(sampling: .greedy)
        )
        let options = response.content.options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !options.isEmpty else { throw AIGenerationError.emptyResult }
        return Array(options.prefix(3))
    }

    // MARK: - Conversation understanding

    /// Turn one utterance into a structured intent + Kaya's reply.
    /// `stage` describes what Kaya just asked, so "yes" / "8 am" resolve.
    /// `history` is the last few chat lines ("Kaya: …", "User: …") so
    /// replies connect to the conversation instead of standing alone.
    func interpretConversation(
        transcript: String,
        stage: String,
        routineTitles: [String],
        history: [String] = [],
        profile: UserProfile?
    ) async throws -> ConversationIntent {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant in a voice chat.
            The user may speak English, Tagalog, or Taglish — classify the
            intent anyway, and always write the reply in English.
            Interpret what the user means.
            Intents: newGoal (they want a routine for a goal), openRoutine (open/start a
            saved routine), start (begin the pending routine — "sounds good",
            "let's do it", "I'm ready" all mean start), showSteps, retry
            (generate a different version — "try again", "not quite"),
            edit (revise the pending plan — "revise it", "make it shorter",
            "add a step for X", "change step two"), cancel (drop the pending
            routine — "never mind", "forget it", "cancel that"),
            restart (scrap the conversation entirely — "start over",
            "from scratch"), answer (they answered your question — extract any
            schedule details), chat (small talk — greetings, "how are you",
            "thanks", feelings like "i'm tired" or "i'm bored", jokes, or
            questions about Kaya or what she can do), progress (questions
            about the user's own results or what's left — "how am I doing",
            "did I finish my routine", "what did I skip", "what's planned
            today"), suggest (asking what to do — "what should I do now",
            "suggest something", "ano gagawin ko"). For progress and suggest,
            a short encouraging reply is fine — the app fills in the real
            details itself.
            If the user shared a durable fact about themselves — a preference,
            schedule, sensitivity, or circumstance that will still be true
            later ("I work night shifts", "loud sounds are hard", "I live
            with my lola") — restate it in a few words in learnedFact. Leave
            learnedFact empty for temporary states ("i'm tired"), questions,
            or anything not about the user personally.
            For every intent EXCEPT chat, the reply just acknowledges what
            Kaya is doing — like "Making your routine" or "Opening it" —
            never write steps, never offer extra help.
            For chat, the reply is the actual answer: warm, human, one or two
            short sentences. Respond to what they actually said — reference
            their words — never a generic line. Acknowledge feelings, answer
            questions about yourself honestly (you're an on-device assistant
            that turns goals into small steps), and you may end with one
            gentle question or suggestion if it fits — like a supportive
            friend would. If earlier lines are shown, build on them; never
            repeat something Kaya already said.
            If they say something you can't do (like checking the weather),
            say so kindly and mention what you can do.
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name)."
        }
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        var prompt = "Conversation stage: \(stage)\n"
        if !history.isEmpty {
            prompt += "Recent chat:\n" + history.joined(separator: "\n") + "\n"
        }
        prompt += "They said: \"\(transcript)\"\n"
        if !routineTitles.isEmpty {
            prompt += "Saved routines: \(routineTitles.joined(separator: ", "))\n"
        }
        prompt += "If they named a day like 'Fridays', put its number in weekday. If they gave a time, put minutes since midnight."

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: ConversationIntent.self,
            options: GenerationOptions(sampling: .greedy)
        )
        return response.content
    }

    /// Edit a draft with plain words — "make step 3 shorter", "add a step
    /// for locking the door". Returns a revised draft; nil result throws.
    func editDraft(
        draft: RoutineDraft,
        instruction: String,
        profile: UserProfile?
    ) async throws -> RoutineDraft {
        guard availability == .available else { throw AIGenerationError.unavailable }

        let stepList = draft.steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title): \($0.element.instruction)" }
            .joined(separator: "\n")

        var instructions = Self.routineInstructions
        instructions += """

            The user is editing an existing routine by talking to you.
            Apply their change and return the full updated routine. Keep every
            step they didn't ask to change. Keep it 3 to 8 steps.
            """
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let prompt = """
            Routine: \(draft.title)
            Steps:
            \(stepList)

            Change requested: \(instruction)
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedRoutine.self,
            options: GenerationOptions(sampling: .greedy)
        )
        let generated = response.content
        guard !generated.steps.isEmpty else { throw AIGenerationError.emptyResult }

        var edited = draft
        edited.title = generated.title
        edited.steps = generated.steps.prefix(8).map { step in
            StepDraft(
                title: step.title,
                instruction: step.instruction,
                doneDescription: step.doneDescription,
                symbolName: UIImage(systemName: step.symbol) != nil ? step.symbol : "checkmark.circle",
                estimatedMinutes: max(step.estimatedMinutes, 0)
            )
        }
        return edited
    }

    // MARK: - Adaptive steps

    /// Rewrite one instruction plainer — for "say it simpler".
    func simplifyStep(
        title: String,
        instruction: String,
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            Rewrite a routine step so it is plainer and shorter — under ten
            words if possible. Keep the same meaning. Literal language only.
            """
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Step: \(title)\nInstruction: \(instruction)",
            generating: SimplifiedStep.self,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.simplerInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// Split a step into micro-actions — for "break it down" or a hard step.
    func breakDownStep(
        title: String,
        instruction: String,
        routineTitle: String,
        profile: UserProfile?
    ) async throws -> [String] {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            Break a routine step into 2 or 3 smaller actions in order.
            Each is one short, literal sentence. No new concepts or tools.
            """
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Routine: \(routineTitle)\nStep: \(title)\nInstruction: \(instruction)",
            generating: BrokenDownStep.self,
            options: GenerationOptions(sampling: .greedy)
        )
        let steps = response.content.microSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steps.isEmpty else { throw AIGenerationError.emptyResult }
        return Array(steps.prefix(3))
    }

    /// Regenerate a routine gentler — smaller steps, more support — after the
    /// user said it felt hard. Returns a fresh draft of the same goal.
    func gentlerVariant(
        routine: Routine,
        profile: UserProfile?
    ) async throws -> RoutineDraft {
        guard availability == .available else { throw AIGenerationError.unavailable }

        let stepList = routine.sortedSteps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title): \($0.element.instruction)" }
            .joined(separator: "\n")

        var instructions = Self.routineInstructions
        instructions += """

            The user finished this routine and said it felt hard.
            Rewrite it gentler: break difficult steps into smaller ones, add
            short rests or setup steps where they help, keep the same goal.
            """
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        var prompt = """
            Goal: \(routine.goal.isEmpty ? routine.title : routine.goal)
            Previous steps:
            \(stepList)
            """
        if let note = routine.lastUserNote, !note.isEmpty {
            prompt += "\nIn their own words, last time: \(note). Work around it if you can."
        }
        let skippedTitles = routine.sortedSteps.filter(\.skipped).map(\.title)
        if !skippedTitles.isEmpty {
            prompt += "\nThey skipped last time: \(skippedTitles.joined(separator: ", ")). Make those steps smaller or optional-feeling."
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedRoutine.self,
            options: GenerationOptions(sampling: .greedy)
        )
        let generated = response.content
        guard !generated.steps.isEmpty else { throw AIGenerationError.emptyResult }

        return RoutineDraft(
            title: generated.title,
            goal: routine.goal.isEmpty ? routine.title : routine.goal,
            steps: generated.steps.prefix(8).map { step in
                StepDraft(
                    title: step.title,
                    instruction: step.instruction,
                    doneDescription: step.doneDescription,
                    symbolName: UIImage(systemName: step.symbol) != nil ? step.symbol : "checkmark.circle",
                    estimatedMinutes: max(step.estimatedMinutes, 0)
                )
            },
            generatedByAI: true,
            speakInstructions: routine.speakInstructions,
            useSimpleInstructions: routine.useSimpleInstructions,
            languageCode: routine.languageCode,
            deadline: routine.deadline
        )
    }

    // MARK: - Proactive coaching

    /// One calm line about what's on today's calendar — for the Home screen.
    /// `recentOutcome` is a deterministic fact about how things went lately
    /// (e.g. "Yesterday 'Making lunch' felt hard") the model may gently
    /// acknowledge — it can suggest the easier version, never pressure.
    func dayBriefing(
        routineTitles: [String],
        times: [String],
        recentOutcome: String? = nil,
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            Write one short, calm sentence telling the user what is planned
            today. No urgency, no pressure, no emojis. Mention the routine
            name and its time if there is one.
            Only describe what is planned. Do not ask questions or offer help.
            If a recent outcome is given, you may gently acknowledge it —
            for example noting an easier version exists — without pressure.
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name)."
        }

        var prompt = "Planned today: \(routineTitles.joined(separator: ", ")) at \(times.joined(separator: ", "))"
        if let recentOutcome, !recentOutcome.isEmpty {
            prompt += "\nRecent outcome: \(recentOutcome)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// "You'll need: keys, a jacket" — items implied by the steps.
    func prepareItems(
        routineTitle: String,
        stepSummaries: [String]
    ) async throws -> [String] {
        guard availability == .available else { throw AIGenerationError.unavailable }

        let session = LanguageModelSession(instructions: """
            You are Kaya, a respectful everyday task assistant.
            List concrete items the user will need for a routine, based only
            on its steps. Everyday objects only — no advice, no quantities.
            """)
        let response = try await session.respond(
            to: "Routine: \(routineTitle)\nSteps:\n" + stepSummaries.joined(separator: "\n"),
            generating: ItemChecklist.self,
            options: GenerationOptions(sampling: .greedy)
        )
        return response.content.items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(5).map { $0 }
    }

    /// A short, honest weekly note for the Progress tab.
    func weeklySummary(
        finishedThisWeek: Int,
        totalFinished: Int,
        hardestTitle: String?,
        hardestNote: String? = nil,
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            Write one or two short sentences reflecting on the user's week.
            Honest and calm — acknowledge real numbers only. If the week was
            quiet, say so gently without blame. No emojis, no streaks.
            Only describe the week. Do not ask questions. Do not offer help.
            Never write anything like "I'm here to help".
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name)."
        }

        var prompt = "Routines finished this week: \(finishedThisWeek)\nRoutines finished all time: \(totalFinished)\n"
        if let hardestTitle {
            prompt += "One routine felt hard for them: \(hardestTitle)\n"
            if let hardestNote, !hardestNote.isEmpty {
                prompt += "In their own words about it: \(hardestNote)\n"
            }
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// Compress the profile's free-text answers into one tight context line
    /// stored on the profile — keeps every future prompt short.
    func distillProfile(profile: UserProfile) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        // Build from the raw answers directly — never from the summary itself.
        var parts: [String] = []
        if !profile.hardThingsText.isEmpty { parts.append("hard things: \(profile.hardThingsText)") }
        if !profile.helpfulThingsText.isEmpty { parts.append("what helps: \(profile.helpfulThingsText)") }
        if !profile.extraContext.isEmpty { parts.append(profile.extraContext) }
        if !profile.commonGoalsText.isEmpty { parts.append("common goals: \(profile.commonGoalsText)") }
        if !profile.learnedFacts.isEmpty { parts.append("remembered: \(profile.learnedFacts.joined(separator: ", "))") }
        let raw = parts.joined(separator: "; ")
        guard !raw.isEmpty else { throw AIGenerationError.emptyResult }

        let session = LanguageModelSession(instructions: """
            Summarize what a task-planning assistant should remember about a
            user, in one sentence of keywords and short phrases. Facts only —
            no opinions, no advice, no invented details.
            """)
        let response = try await session.respond(
            to: raw,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// Compress the user's own words about how a run went into one short,
    /// honest note — stored on the routine and fed back into future prompts.
    /// "the blender was way too loud" → "found the blender too loud".
    func distillJournal(_ raw: String, routineTitle: String) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        let session = LanguageModelSession(instructions: """
            You are Kaya, a respectful everyday task assistant.
            The user just described how a routine went, in their own words.
            Rewrite it as one short factual note in third person, a few words
            — what went well or what was hard. Keep their meaning exactly;
            no advice, no opinions, no invented details.
            """)
        let response = try await session.respond(
            to: "Routine: \(routineTitle)\nThey said: \"\(raw)\"",
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// Pick ONE routine the user could do right now and say why, gently.
    /// The candidates are supplied by the app — the model only chooses and
    /// phrases, it never invents routines.
    func suggestNext(candidates: [String], profile: UserProfile?) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            The user asked what to do next. Pick ONE routine from the list —
            favor the one that fits the time of day or is already started —
            and say why in one short, calm sentence. Name it exactly as listed.
            No pressure, no lists, no questions. If nothing fits, say so kindly.
            """
        if let name = profile?.name, !name.isEmpty {
            instructions += "\nThe user is called \(name)."
        }
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "It's about \(hour):00. Candidates:\n" + candidates.joined(separator: "\n"),
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }

    /// One short, plain answer to a question the user asked mid-step —
    /// "why do I rinse first?", "what does sift mean?". Spoken aloud, so
    /// keep it to a breath or two and stay inside the current step.
    func answerStepQuestion(
        step: String,
        instruction: String,
        routineTitle: String,
        question: String,
        profile: UserProfile?
    ) async throws -> String {
        guard availability == .available else { throw AIGenerationError.unavailable }

        var instructions = """
            You are Kaya, a respectful everyday task assistant.
            The user is doing a routine and asked a question about the
            current step. Answer in one short sentence of plain, literal
            language — enough to unblock them, nothing more. No questions
            back, no extra advice. If the question is unrelated to the step
            or outside what an everyday task helper can answer, say so kindly
            in one short sentence and point back to the step.
            """
        if let context = Self.userContextSummary(profile), !context.isEmpty {
            instructions += "\nUser context: \(context)"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: """
                Routine: \(routineTitle)
                Current step: \(step) — \(instruction)
                Question: \(question)
                """,
            options: GenerationOptions(sampling: .greedy)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIGenerationError.emptyResult }
        return text
    }
}
