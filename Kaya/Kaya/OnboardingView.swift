//
//  OnboardingView.swift
//  Kaya
//
//  First-launch flow: name, task questions, and preferences that personalize
//  the on-device AI. Can also re-open later to update your answers.
//  Everything stays on the device.
//

import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// When set, edits that profile instead of creating a new one.
    private let existing: UserProfile?

    @State private var page = 0
    @State private var moveForward = true
    @State private var name = ""
    @State private var stepSize: StepSizePreference = .regular
    @State private var selectedGoals: Set<String> = []
    @State private var selectedHards: Set<String> = []
    @State private var helpfulThings = ""
    @State private var prefersShortSteps = true
    @State private var wantsSpokenInstructions = false
    @State private var wantsVoiceControl = true
    @State private var encouragement: EncouragementLevel = .some
    @State private var extraContext = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One question per page — welcome, then six focused questions.
    private let pageCount = 8

    private let goalOptions = [
        "Get ready for school or work", "Make a meal", "Go shopping",
        "Clean up my space", "Go to an appointment", "Go somewhere new"
    ]
    private let hardOptions = [
        "Noise", "Crowds", "Remembering steps", "Getting started",
        "Changes in plans", "Too many words", "Doing things alone"
    ]

    init(existing: UserProfile? = nil) {
        self.existing = existing
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KayaTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    if page > 0 { progressDots.padding(.top, 12) }
                    currentPage
                        .id(page)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: moveForward ? .trailing : .leading)
                                        .combined(with: .opacity),
                                    removal: .move(edge: moveForward ? .leading : .trailing)
                                        .combined(with: .opacity)
                                )
                        )
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            moveForward = false
                            page -= 1
                        } label: {
                            Image(systemName: "chevron.left")
                                .foregroundStyle(KayaTheme.text)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Back")
                    }
                }
            }
        }
        .onAppear {
            #if DEBUG
            if let pageEnv = ProcessInfo.processInfo.environment["KAYA_ONBOARD_PAGE"],
               let pageValue = Int(pageEnv) {
                page = pageValue
            }
            #endif
            guard let existing else { return }
            name = existing.name
            stepSize = existing.stepSize
            selectedGoals = Set(existing.commonGoalsText.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            selectedHards = Set(existing.hardThingsText.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            helpfulThings = existing.helpfulThingsText
            prefersShortSteps = existing.prefersShortSteps
            wantsSpokenInstructions = existing.wantsSpokenInstructions
            wantsVoiceControl = existing.wantsVoiceControl
            encouragement = existing.encouragement
            extraContext = existing.extraContext
        }
    }

    // MARK: - Page 1: welcome + name

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.wave.fill")
                .font(.system(size: 44))
                .foregroundStyle(KayaTheme.onAccent)
                .frame(width: 96, height: 96)
                .background(KayaTheme.accent)
                .clipShape(Circle())
                .accessibilityHidden(true)

            Text(existing == nil ? "Hi, I'm Kaya" : "Update your answers")
                .font(.largeTitle.bold())
                .foregroundStyle(KayaTheme.text)

            Text("I turn your goals into calm, step-by-step routines — right here on your device.")
                .font(.title3)
                .foregroundStyle(KayaTheme.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                Text("What should I call you?")
                    .font(.headline)
                    .foregroundStyle(KayaTheme.text)
                TextField("Your name (optional)", text: $name)
                    .font(.body)
                    .foregroundStyle(KayaTheme.text)
                    .padding(14)
                    .background(KayaTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(KayaTheme.warm, lineWidth: 2)
                    )
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                moveForward = true
                page = 1
            } label: {
                Text(name.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Continue" : "Continue, \(name.trimmingCharacters(in: .whitespaces))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KayaPrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step-by-step pages

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case 0: welcomePage
        case 1: stepSizePage
        case 2: goalsPage
        case 3: hardsPage
        case 4: helpsPage
        case 5: encouragementPage
        case 6: talkingPage
        default: anythingElsePage
        }
    }

    /// One pip per question page — a long capsule marks where you are.
    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(1..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index <= page ? KayaTheme.accent : KayaTheme.warm)
                    .frame(width: index == page ? 22 : 7, height: 7)
                    .animation(reduceMotion ? nil : .spring(response: 0.3), value: page)
            }
        }
        .accessibilityHidden(true)
    }

    /// The shared layout for a single-question page: icon, question,
    /// one-line detail, content, and a Continue button pinned at the bottom.
    private func stepPage<Content: View>(
        symbol: String,
        question: String,
        detail: String,
        nextTitle: String = "Continue",
        next: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    KayaIconTile(symbol: symbol, size: 60)
                        .padding(.top, 18)
                    Text(question)
                        .font(.largeTitle.bold())
                        .foregroundStyle(KayaTheme.text)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(KayaTheme.subtleText)
                        .padding(.bottom, 14)
                    content()
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
            }
            Button(nextTitle) { next() }
                .buttonStyle(KayaPrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    private func nextPage() {
        moveForward = true
        page += 1
    }

    /// Page 1 — how big should each step be.
    private var stepSizePage: some View {
        stepPage(
            symbol: "list.number",
            question: "How much can you do at once?",
            detail: "This decides how big each step is.",
            next: nextPage
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(StepSizePreference.allCases, id: \.self) { size in
                    Button {
                        stepSize = size
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: stepSize == size ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(stepSize == size ? KayaTheme.accent : KayaTheme.subtleText)
                                .contentTransition(.symbolEffect(.replace))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(size.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(KayaTheme.text)
                                Text(size.detail)
                                    .font(.caption)
                                    .foregroundStyle(KayaTheme.subtleText)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(stepSize == size ? KayaTheme.warm : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(KayaChipButtonStyle())
                }
            }
            .kayaCard()
        }
    }

    /// Page 2 — routines to suggest.
    private var goalsPage: some View {
        stepPage(
            symbol: "star.fill",
            question: "What do you do often?",
            detail: "Kaya will suggest routines like these.",
            next: nextPage
        ) {
            chipGrid(options: goalOptions, selection: $selectedGoals)
                .kayaCard()
        }
    }

    /// Page 3 — what to soften in generated steps.
    private var hardsPage: some View {
        stepPage(
            symbol: "mountain.2.fill",
            question: "What makes tasks hard for you?",
            detail: "Kaya will shape steps to make these easier. Pick any that fit — or none.",
            next: nextPage
        ) {
            chipGrid(options: hardOptions, selection: $selectedHards)
                .kayaCard()
        }
    }

    /// Page 4 — optional free text on what helps.
    private var helpsPage: some View {
        stepPage(
            symbol: "heart.fill",
            question: "What helps you?",
            detail: "Optional — Kaya builds these into steps when they fit.",
            next: nextPage
        ) {
            TextField("For example: quiet spaces, lists, taking breaks, someone nearby",
                      text: $helpfulThings, axis: .vertical)
                .font(.body)
                .foregroundStyle(KayaTheme.text)
                .lineLimit(2...4)
                .padding(14)
                .background(KayaTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(KayaTheme.warm, lineWidth: 2)
                )
        }
    }

    /// Page 5 — how much praise to give.
    private var encouragementPage: some View {
        stepPage(
            symbol: "hand.thumbsup.fill",
            question: "How much encouragement?",
            detail: "Calm praise for finishing steps — never pressure, never guilt.",
            next: nextPage
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(EncouragementLevel.allCases, id: \.self) { level in
                    Button {
                        encouragement = level
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: encouragement == level ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(encouragement == level ? KayaTheme.accent : KayaTheme.subtleText)
                                .contentTransition(.symbolEffect(.replace))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(KayaTheme.text)
                                Text(encouragementDetail(level))
                                    .font(.caption)
                                    .foregroundStyle(KayaTheme.subtleText)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(encouragement == level ? KayaTheme.warm : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(KayaChipButtonStyle())
                }
            }
            .kayaCard()
        }
    }

    private func encouragementDetail(_ level: EncouragementLevel) -> String {
        switch level {
        case .quiet: return "No praise — just the steps."
        case .some: return "A small kind word when a step is done."
        case .lots: return "Kaya cheers you on after every step."
        }
    }

    /// Page 6 — how Kaya should talk and listen.
    private var talkingPage: some View {
        stepPage(
            symbol: "slider.horizontal.3",
            question: "How should Kaya talk to you?",
            detail: "You can change all of this anytime from the You tab.",
            next: nextPage
        ) {
            VStack(spacing: 4) {
                Toggle("Short, simple instructions", isOn: $prefersShortSteps)
                    .tint(KayaTheme.accent)
                    .padding(.vertical, 6)
                Toggle("Read steps aloud", isOn: $wantsSpokenInstructions)
                    .tint(KayaTheme.accent)
                    .padding(.vertical, 6)
                Toggle("Hands-free voice control", isOn: $wantsVoiceControl)
                    .tint(KayaTheme.accent)
                    .padding(.vertical, 6)
            }
            .kayaCard()
        }
    }

    /// Page 7 — anything else, then finish.
    private var anythingElsePage: some View {
        stepPage(
            symbol: "text.bubble.fill",
            question: "Anything else Kaya should know?",
            detail: "Optional. Stays on this device and quietly guides the on-device AI.",
            nextTitle: existing == nil ? "Start using Kaya" : "Save my answers",
            next: finish
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("For example: keep instructions very short, loud places are hard for me",
                          text: $extraContext, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(KayaTheme.text)
                    .lineLimit(3...5)
                    .padding(14)
                    .background(KayaTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(KayaTheme.warm, lineWidth: 2)
                    )
                Label("Everything stays on this device.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }
        }
    }

    private func chipGrid(options: [String], selection: Binding<Set<String>>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isOn = selection.wrappedValue.contains(option)
                Button {
                    if isOn {
                        selection.wrappedValue.remove(option)
                    } else {
                        selection.wrappedValue.insert(option)
                    }
                } label: {
                    Text(option)
                        .font(.subheadline)
                        .foregroundStyle(isOn ? KayaTheme.onAccent : KayaTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isOn ? KayaTheme.accent : KayaTheme.warm)
                        .clipShape(Capsule())
                }
                .buttonStyle(KayaChipButtonStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func finish() {
        let goals = goalOptions.filter { selectedGoals.contains($0) }.joined(separator: ", ")
        let hards = hardOptions.filter { selectedHards.contains($0) }.joined(separator: ", ")

        let profile: UserProfile
        if let existing {
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.stepSizeRaw = stepSize.rawValue
            existing.commonGoalsText = goals
            existing.hardThingsText = hards
            existing.helpfulThingsText = helpfulThings.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.prefersShortSteps = prefersShortSteps
            existing.wantsSpokenInstructions = wantsSpokenInstructions
            existing.wantsVoiceControl = wantsVoiceControl
            existing.encouragementRaw = encouragement.rawValue
            existing.extraContext = extraContext.trimmingCharacters(in: .whitespacesAndNewlines)
            profile = existing
        } else {
            let created = UserProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                prefersShortSteps: prefersShortSteps,
                wantsSpokenInstructions: wantsSpokenInstructions,
                wantsVoiceControl: wantsVoiceControl,
                encouragement: encouragement,
                extraContext: extraContext.trimmingCharacters(in: .whitespacesAndNewlines),
                stepSize: stepSize,
                commonGoals: goals,
                hardThings: hards,
                helpfulThings: helpfulThings.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(created)
            profile = created
        }
        try? modelContext.save()
        distillProfileContext(profile)
        dismiss()
    }

    /// Compresses the answers into one context line on-device, in the
    /// background — future AI prompts stay short and personal.
    private func distillProfileContext(_ profile: UserProfile) {
        Task {
            if let summary = try? await LocalAIService().distillProfile(profile: profile) {
                profile.aiContextSummary = summary
                try? modelContext.save()
            }
        }
    }
}
