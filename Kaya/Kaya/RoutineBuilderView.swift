//
//  RoutineBuilderView.swift
//  Kaya
//
//  Turn a natural-language goal into steps with on-device AI.
//

import SwiftData
import SwiftUI

struct RoutineBuilderView: View {
    @Query private var profiles: [UserProfile]
    @State private var aiService = LocalAIService()
    @State private var voice = VoiceService()

    @State private var goal = ""
    @State private var useSimpleInstructions = true
    @State private var speakInstructions = false
    @State private var showIcons = true
    @State private var languageCode = "en"
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(60 * 60)

    @State private var isGenerating = false
    @State private var generationFailed = false
    @State private var availability: AIAvailability = .available
    @State private var draftToReview: RoutineDraft?
    @State private var autoGenerateOnAppear: Bool
    @State private var dictationTask: Task<Void, Never>?
    @State private var appliedProfileDefaults = false

    private var profile: UserProfile? { profiles.first }

    @FocusState private var goalFieldFocused: Bool

    init(initialGoal: String = "", autoGenerate: Bool = false) {
        _goal = State(initialValue: initialGoal)
        _autoGenerateOnAppear = State(initialValue: autoGenerate)
    }

    private var canGenerate: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && availability == .available
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                goalSection
                suggestionsSection
                preferencesSection
                goodToKnowCard

                if availability != .available {
                    unavailableCard
                }

                if generationFailed {
                    errorCard
                }

                if isGenerating {
                    generatingCard
                } else {
                    actionButtons
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(KayaTheme.background.ignoresSafeArea())
        .navigationTitle("Create a routine")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { availability = aiService.availability }
        .task {
            availability = aiService.availability
            if !appliedProfileDefaults, let profile {
                appliedProfileDefaults = true
                useSimpleInstructions = profile.prefersShortSteps
                speakInstructions = profile.wantsSpokenInstructions
            }
            if autoGenerateOnAppear {
                autoGenerateOnAppear = false
                if availability == .available, !goal.isEmpty {
                    generate()
                }
            }
        }
        .onDisappear {
            dictationTask?.cancel()
            voice.stopListening()
        }
        .navigationDestination(item: $draftToReview) { draft in
            RoutineReviewView(draft: draft)
        }
    }

    // MARK: - Sections

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What would you like to do?")
                    .font(.title3.bold())
                    .foregroundStyle(KayaTheme.text)
                Spacer()
                VoiceOrb(isListening: voice.isListening, isSpeaking: false, size: 40) {
                    toggleDictation()
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel(voice.isListening ? "Stop dictating" : "Dictate your goal")
            }

            if voice.isListening {
                Text("Listening… pause when you're done and Kaya will take it from there.")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.accent)
            } else if voice.permissionDenied || voice.isUnsupported {
                Text("Voice input isn't available — you can type instead.")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $goal)
                    .focused($goalFieldFocused)
                    .font(.body)
                    .foregroundStyle(KayaTheme.text)
                    .frame(minHeight: 110)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(KayaTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(KayaTheme.warm, lineWidth: 2)
                    )
                    .accessibilityLabel("Your goal")
                    .accessibilityHint("Describe what you want to do in your own words")

                if goal.isEmpty {
                    Text("For example: I want to buy bread at the grocery store.")
                        .font(.body)
                        .foregroundStyle(KayaTheme.subtleText.opacity(0.7))
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// The user's own "things I do often" answers come first, then defaults.
    private var suggestions: [String] {
        var result: [String] = []
        if let goals = profile?.commonGoalsText, !goals.isEmpty {
            result += goals.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        result += RoutineStore.suggestedGoals
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0).inserted }.prefix(7))
    }

    /// Quick notes about what happens after the routine is created —
    /// deadlines, difficulty check-ins, photos, and AI messages.
    private var goodToKnowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Good to know")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)

            bullet("flag", "Set a finish-by time below — Kaya checks the steps fit. No countdowns.")
            bullet("mic.fill", "While doing a routine, just talk — “done”, “repeat”, “help”. No buttons needed.")
            bullet("text.bubble", "When you finish, you can say how it felt — Kaya writes you a message on-device.")
            bullet("photo", "You can keep a photo of what you did — it stays on this device.")
            bullet("arrow.counterclockwise", "Finished routines can be repeated anytime from Progress.")
        }
        .kayaCard()
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(KayaTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(KayaTheme.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or pick an idea")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)

            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        goal = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(KayaTheme.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(KayaTheme.warm)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preferences")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)
                .padding(.bottom, 6)

            Toggle("Simple instructions", isOn: $useSimpleInstructions)
                .toggleStyle(SwitchToggleStyle(tint: KayaTheme.accent))
                .padding(.vertical, 6)
            Toggle("Speak instructions aloud", isOn: $speakInstructions)
                .toggleStyle(SwitchToggleStyle(tint: KayaTheme.accent))
                .padding(.vertical, 6)
            Toggle("Show icons", isOn: $showIcons)
                .toggleStyle(SwitchToggleStyle(tint: KayaTheme.accent))
                .padding(.vertical, 6)
            Toggle("Set a finish-by time", isOn: $hasDeadline)
                .toggleStyle(SwitchToggleStyle(tint: KayaTheme.accent))
                .padding(.vertical, 6)
                .accessibilityHint("Optional. Kaya checks if the steps fit — no countdowns or pressure.")

            if hasDeadline {
                DatePicker("Finish by", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                    .tint(KayaTheme.accent)
                    .padding(.vertical, 4)
                Text("Kaya and the on-device AI will check that the steps fit. It's a guide, never a timer.")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }

            Text("Language")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.text)
                .padding(.top, 10)
            Picker("Language", selection: $languageCode) {
                Text("English").tag("en")
                Text("Filipino").tag("fil")
            }
            .pickerStyle(.segmented)

            if languageCode == "fil" {
                Text("Filipino support depends on the on-device model. Steps may appear in English if Filipino is not supported on this device.")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
                    .padding(.top, 4)
            }
        }
        .kayaCard()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On-device AI is not available right now", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)
            Text(availability.message)
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
            Button("Check again") {
                availability = aiService.availability
            }
            .font(.subheadline.bold())
            .foregroundStyle(KayaTheme.accent)
            .frame(minHeight: 44)
        }
        .kayaCard()
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("That didn't work", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)
            Text("The on-device model could not make steps this time. You can try again or write your own steps.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
        }
        .kayaCard()
    }

    private var generatingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(KayaTheme.accent)
            Text("Preparing your steps…")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)
            Text("On-device AI is working on this device. Nothing leaves your phone.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .kayaCard(padding: 28)
        .accessibilityElement(children: .combine)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if availability == .available {
                Button {
                    generate()
                } label: {
                    Label("Create my steps", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KayaPrimaryButtonStyle())
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .accessibilityHint("Uses on-device AI to turn your goal into steps")
            }

            NavigationLink(value: manualDraft) {
                Text("Write my own steps")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KayaSecondaryButtonStyle())
            .accessibilityHint("Create a routine by typing each step yourself")
        }
    }

    // MARK: - Actions

    private var manualDraft: RoutineDraft {
        var draft = RoutineDraft.blank
        draft.goal = goal
        draft.speakInstructions = speakInstructions
        draft.useSimpleInstructions = useSimpleInstructions
        draft.languageCode = languageCode
        draft.deadline = hasDeadline ? deadline : nil
        return draft
    }

    // MARK: - Dictation

    private func toggleDictation() {
        if voice.isListening {
            finishDictation(generate: true)
            return
        }
        Task {
            guard await voice.enable() else { return }
            voice.onTranscript = {
                goal = voice.transcript
                scheduleDictationStop()
            }
            voice.startListening()
        }
    }

    private func scheduleDictationStop() {
        dictationTask?.cancel()
        let snapshot = voice.transcript
        dictationTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, voice.transcript == snapshot, !snapshot.isEmpty else { return }
            finishDictation(generate: true)
        }
    }

    private func finishDictation(generate shouldGenerate: Bool) {
        dictationTask?.cancel()
        voice.stopListening()
        if !voice.transcript.isEmpty {
            goal = voice.transcript
        }
        if shouldGenerate, canGenerate {
            generate()
        }
    }

    private func generate() {
        isGenerating = true
        generationFailed = false
        goalFieldFocused = false

        Task {
            do {
                var draft = try await aiService.generateRoutine(
                    goal: goal,
                    useSimpleInstructions: useSimpleInstructions,
                    languageCode: languageCode,
                    profile: profile,
                    deadline: hasDeadline ? deadline : nil
                )
                draft.speakInstructions = speakInstructions
                if !showIcons {
                    draft.steps = draft.steps.map {
                        StepDraft(id: $0.id, title: $0.title, instruction: $0.instruction,
                                  doneDescription: $0.doneDescription, symbolName: "")
                    }
                }
                draftToReview = draft
            } catch {
                generationFailed = true
                availability = aiService.availability
            }
            isGenerating = false
        }
    }
}

// MARK: - Simple wrapping layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
