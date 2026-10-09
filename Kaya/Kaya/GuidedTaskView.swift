//
//  GuidedTaskView.swift
//  Kaya
//
//  One step at a time. Voice-first: Kaya reads each step, listens,
//  and advances when you say "done". Buttons remain as a fallback.
//

import Combine
import PhotosUI
import SwiftData
import SwiftUI

struct GuidedTaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [UserProfile]

    let routine: Routine

    @State private var speech = SpeechService()
    @State private var voice = VoiceService()
    @State private var aiService = LocalAIService()
    @State private var handsFree = false
    @State private var isPaused = false
    @State private var showHelp = false
    @State private var showSomethingChanged = false
    @State private var showStepsOverview = false
    @State private var announcedFinish = false
    @State private var voiceNote: String?
    @State private var newMilestones: [Milestone] = []
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var reflectionLoading = false
    @State private var stepStartedAt = Date()
    @State private var checkAppeared = false
    @State private var paceOffered = false
    @State private var simplifyInFlight = false
    @State private var gentlerApplied = false
    @State private var gentlerWorking = false
    /// Post-finish journal: Kaya asks once how it went, one utterance is
    /// captured and AI-distilled onto the routine for next time.
    @State private var awaitingJournal = false
    @State private var journalAsked = false
    @State private var journalTask: Task<Void, Never>?
    /// Mid-step questions ("why do I rinse first?") — debounced so partial
    /// transcripts don't fire answers mid-sentence.
    @State private var questionInFlight = false
    @State private var questionTask: Task<Void, Never>?

    /// Slow tick driving the gentle pace check-in — not shown on screen.
    private let paceTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var profile: UserProfile? { profiles.first }

    private var steps: [RoutineStepRecord] { routine.sortedSteps }
    private var stepCount: Int { steps.count }

    private var currentIndex: Int {
        min(max(routine.currentStepIndex, 0), max(stepCount - 1, 0))
    }

    private var currentStep: RoutineStepRecord? {
        guard stepCount > 0 else { return nil }
        return steps[currentIndex]
    }

    private var isLastStep: Bool { currentIndex == stepCount - 1 }
    private var shouldSpeak: Bool { routine.speakInstructions || handsFree }

    var body: some View {
        NavigationStack {
            ZStack {
                KayaTheme.background.ignoresSafeArea()

                if routine.isFinished {
                    completionView
                } else {
                    stepView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exitRoutine()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.bold())
                            .foregroundStyle(KayaTheme.text)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Close and save progress")
                }
                ToolbarItem(placement: .principal) {
                    if !routine.isFinished, stepCount > 0 {
                        Text("Step \(currentIndex + 1) of \(stepCount)")
                            .font(.headline)
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !routine.isFinished {
                        Menu {
                            Button {
                                goToPrevious()
                            } label: {
                                Label("Previous step", systemImage: "chevron.left")
                            }
                            .disabled(currentIndex == 0)
                            Button {
                                repeatStep()
                            } label: {
                                Label("Repeat instruction", systemImage: "arrow.clockwise")
                            }
                            Button {
                                simplifyCurrentStep()
                            } label: {
                                Label("Make this step easier", systemImage: "sparkles")
                            }
                            .disabled(simplifyInFlight)
                            Button {
                                voice.stopListening()
                                showStepsOverview = true
                            } label: {
                                Label("See all steps", systemImage: "list.bullet")
                            }
                            Button {
                                pauseRoutine()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            Divider()
                            Button {
                                voice.stopListening()
                                showHelp = true
                            } label: {
                                Label("I need help", systemImage: "hand.raised.fill")
                            }
                            Button {
                                voice.stopListening()
                                showSomethingChanged = true
                            } label: {
                                Label("Something changed", systemImage: "arrow.triangle.2.circlepath")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body.bold())
                                .foregroundStyle(KayaTheme.text)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("More options")
                        .accessibilityHint("Or say: repeat, back, pause, help, something changed")
                    }
                }
            }
            .sheet(isPresented: $showHelp, onDismiss: resumeAfterSheet) {
                HelpView(
                    onStopRoutine: {
                        voice.stopListening()
                        speech.stop()
                        RoutineStore.touch(routine, in: modelContext)
                        dismiss()
                    },
                    languageCode: routine.languageCode
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showStepsOverview, onDismiss: resumeAfterSheet) {
                stepsOverviewSheet
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSomethingChanged, onDismiss: resumeAfterSheet) {
                SomethingChangedView(
                    routineTitle: routine.title,
                    stepTitle: currentStep?.title ?? "",
                    onSkipStep: skipCurrentStep,
                    onPause: { isPaused = true },
                    onGetHelp: { showHelp = true }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            if routine.startedAt == nil {
                routine.startedAt = Date()
            }
            stepStartedAt = Date()
            RoutineStore.touch(routine, in: modelContext)
            voice.onTranscript = handleTranscript
            if routine.speakInstructions {
                narrateCurrent()
            }
            if profile?.wantsVoiceControl == true, !handsFree, !routine.isFinished {
                toggleHandsFree()
            }
            if !routine.hasStarted || routine.completedCount == 0 {
                loadPreparedItems()
            }
        }
        .onDisappear {
            voice.stopListening()
            speech.stop()
        }
        .onChange(of: pickedItems) { _, _ in
            loadPickedPhotos()
        }
        .onChange(of: routine.currentStepIndex) { _, _ in
            stepStartedAt = Date()
            paceOffered = false
        }
        .onReceive(paceTimer) { _ in
            checkPace()
        }
        .onChange(of: routine.isFinished) { _, finished in
            if finished, !announcedFinish {
                announcedFinish = true
                voice.stopListening()
                ReminderService.shared.sync(routine)
                if let profile {
                    profile.routinesFinished += 1
                    profile.finishDates.append(Date())
                    if profile.finishDates.count > 200 {
                        profile.finishDates.removeFirst(profile.finishDates.count - 200)
                    }
                    // += not =: the final step may have just earned its own
                    // milestone (appended above) — don't wipe it.
                    newMilestones += Momentum.checkNew(in: profile)
                    try? modelContext.save()
                }
                if shouldSpeak {
                    var message = "You finished \(routine.title). You did it your way, at your own pace."
                    if let milestone = newMilestones.first {
                        message += " You earned a milestone: \(milestone.title)."
                    }
                    if handsFree {
                        message += " Tell me how it felt — easy, okay, or hard."
                    }
                    speech.speak(message, languageCode: routine.languageCode) { [self] in
                        if handsFree { voice.startListening() }
                    }
                }
            }
        }
    }

    // MARK: - Step view

    private var stepView: some View {
        VStack(spacing: 14) {
            stepDots
                .padding(.top, 4)

            bigTimer

            // The card scrolls if it's too tall for the screen, so the
            // dots and timer above are never pushed out of view.
            ScrollView {
                VStack(spacing: 18) {
                    // One-shot, dismissible offer: last run felt hard or had
                    // skips — the model can rebuild this routine gentler.
                    if gentlerOfferVisible {
                        gentlerBanner
                            .transition(.opacity)
                    }

                    if let step = currentStep {
                        if isPaused {
                            pausedCard
                        } else {
                            stepCard(step)
                        }
                    } else {
                        ContentUnavailableView("No steps", systemImage: "list.bullet",
                                               description: Text("This routine has no steps yet."))
                    }

                    // A quiet peek at what's coming — takes the surprise out of
                    // "done" for people who find transitions hard.
                    if !isPaused, !isLastStep, currentStep != nil {
                        nextStepPreview
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            if isPaused {
                pausedControls
            } else {
                voiceControlArea
            }
        }
        .padding(.bottom, 20)
    }

    /// The pre-start easier-version offer — only before step one, only once
    /// per outcome. `lastRunHadSkips`/`gentlerOffered` persist across restart
    /// so the banner survives into the next run but never nags twice.
    private var gentlerOfferVisible: Bool {
        !routine.isFinished && !isPaused && !routine.gentlerOffered
            && routine.completedCount == 0 && currentIndex == 0
            && (routine.difficulty == .hard || routine.lastRunHadSkips)
    }

    private var gentlerBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(routine.difficulty == .hard
                  ? "Last time felt hard"
                  : "A step got skipped last time",
                  systemImage: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.accent)
            Text(gentlerWorking
                 ? "Making it easier — same goal, smaller steps…"
                 : "Want a gentler version? Same goal, smaller steps.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if !gentlerWorking {
                HStack(spacing: 10) {
                    Button("Easier version") {
                        routine.gentlerOffered = true
                        try? modelContext.save()
                        voiceNote = "Making it easier…"
                        applyGentlerVariant()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(KayaTheme.accent))
                    .foregroundStyle(KayaTheme.onAccent)
                    .buttonStyle(KayaChipButtonStyle())

                    Button("Keep as is") {
                        routine.gentlerOffered = true
                        try? modelContext.save()
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(KayaTheme.subtleText)
                    .buttonStyle(KayaChipButtonStyle())
                }
            } else {
                ProgressView()
                    .tint(KayaTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kayaCard(padding: 14)
        .accessibilityElement(children: .contain)
    }

    private func stepCard(_ step: RoutineStepRecord) -> some View {
        VStack(spacing: 18) {
            if !step.symbolName.isEmpty {
                Image(systemName: step.displaySymbol)
                    .font(.system(size: 52))
                    .foregroundStyle(KayaTheme.accent)
                    .symbolEffect(.bounce, options: .nonRepeating, value: step.order)
                    .frame(width: 108, height: 108)
                    .background(
                        Circle().fill(
                            RadialGradient(
                                colors: [KayaTheme.accent.opacity(0.30), KayaTheme.warm],
                                center: .center,
                                startRadius: 6,
                                endRadius: 60
                            )
                        )
                    )
                    .accessibilityHidden(true)
            }

            Text(step.title)
                .font(.largeTitle.bold())
                .foregroundStyle(KayaTheme.text)
                .multilineTextAlignment(.center)

            Text(step.instruction)
                .font(.title3)
                .foregroundStyle(KayaTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !step.doneDescription.isEmpty {
                Label("Done when: \(step.doneDescription)", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.subtleText)
                    .multilineTextAlignment(.center)
            }

            if step.estimatedMinutes > 0 {
                HStack(spacing: 6) {
                    Label("About \(step.estimatedMinutes) min", systemImage: "clock")
                    Text("·")
                    Text(stepStartedAt, style: .timer)
                    Text("in")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(KayaTheme.subtleText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Estimated \(step.estimatedMinutes) minutes. Time on this step is counting up.")
            }
        }
        .frame(maxWidth: .infinity)
        .kayaCard(padding: 28)
        .padding(.horizontal, 20)
        .id(step.order)
        .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
        .contentShape(Rectangle())
        .onTapGesture {
            markDoneAndAdvance()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(currentIndex + 1) of \(stepCount). \(step.title). \(step.instruction)")
        .accessibilityHint("Tap to mark this step done")
        .accessibilityAddTraits(.isButton)
    }

    /// A quiet peek at the step after this one — small, so the current
    /// step stays the focus but the transition isn't a surprise.
    private var nextStepPreview: some View {
        let next = steps[currentIndex + 1]
        return HStack(spacing: 10) {
            Image(systemName: next.displaySymbol)
                .font(.subheadline)
                .foregroundStyle(KayaTheme.accent)
            Text("Up next · \(next.title)")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .lineLimit(1)
            Spacer()
            if next.estimatedMinutes > 0 {
                Text("~\(next.estimatedMinutes) min")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(KayaTheme.warm.opacity(0.4))
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Up next: \(next.title)")
    }

    private var pausedCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(KayaTheme.accent)
                .accessibilityHidden(true)
            Text("Paused")
                .font(.largeTitle.bold())
                .foregroundStyle(KayaTheme.text)
            Text(handsFree
                 ? "Say “resume” when you're ready. Your progress is saved."
                 : "Take all the time you need. Your progress is saved.")
                .font(.title3)
                .foregroundStyle(KayaTheme.subtleText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .kayaCard(padding: 28)
        .padding(.horizontal, 20)
    }

    // MARK: - Voice-first controls

    private var voiceControlArea: some View {
        VStack(spacing: 8) {
            ZStack {
                KayaProgressRing(
                    value: stepCount > 0 ? Double(routine.completedCount) / Double(stepCount) : 0,
                    size: 128,
                    lineWidth: 5
                )
                VoiceOrb(isListening: voice.isListening, isSpeaking: speech.isSpeaking, size: 76) {
                    toggleHandsFree()
                }
            }

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .multilineTextAlignment(.center)
                .frame(minHeight: 40)
                .padding(.horizontal, 24)
                .accessibilityLabel(statusLine)

            // Quiet secondary controls — everything in here is also a voice
            // command; these pills exist for when speaking isn't an option.
            HStack(spacing: 10) {
                quickPill("Repeat", systemImage: "arrow.clockwise") {
                    repeatStep()
                }
                quickPill("Back", systemImage: "chevron.left") {
                    goToPrevious()
                }
                .disabled(currentIndex == 0)
                quickPill("Skip", systemImage: "forward.fill") {
                    skipCurrentStep()
                }
                quickPill("Steps", systemImage: "list.bullet") {
                    voice.stopListening()
                    showStepsOverview = true
                }
            }
        }
    }

    private func quickPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(KayaTheme.warm.opacity(0.55)))
                .overlay(Capsule().stroke(KayaTheme.accent.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(KayaChipButtonStyle())
    }

    private var pausedControls: some View {
        VStack(spacing: 14) {
            VoiceOrb(isListening: voice.isListening, isSpeaking: speech.isSpeaking, size: 64) {
                toggleHandsFree()
            }
            Button {
                isPaused = false
                narrateCurrent()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KayaPrimaryButtonStyle())
            .padding(.horizontal, 20)

            Button {
                exitRoutine()
            } label: {
                Text("Save and exit")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KayaSecondaryButtonStyle())
            .padding(.horizontal, 20)
        }
    }

    private var statusLine: String {
        if let voiceNote { return voiceNote }
        if voice.permissionDenied || voice.isUnsupported {
            return "Voice control is off — tap the step card when it's done."
        }
        if voice.isListening {
            let hearing = voice.unhandled
            return hearing.isEmpty
                ? "Listening… say “done”, “repeat”, “back”, or “help”."
                : "Heard: \(hearing)"
        }
        if speech.isSpeaking { return "Kaya is speaking…" }
        if handsFree { return "Hands-free is on." }
        return "Tap the mic, then just say “done” — or tap the card."
    }

    private var deadlineNote: String? {
        guard let deadline = routine.deadline else { return nil }
        let time = deadline.formatted(date: .omitted, time: .shortened)
        if deadline <= Date() {
            return "Finish-by time passed — still fine, your pace"
        }
        return "Aim \(time)"
    }

    /// "about 12 min left" — sums the AI estimates for steps not yet done.
    /// Only shows when estimates exist; disappears rather than guessing.
    private var remainingCaption: String {
        let left = steps.dropFirst(currentIndex).filter { !$0.isDone && !$0.skipped }
            .reduce(0) { $0 + $1.estimatedMinutes }
        return left > 0 ? "about \(left) min left" : "time on this routine"
    }

    private var finishMinutes: Int? {
        guard let start = routine.startedAt, let end = routine.finishedAt else { return nil }
        return max(1, Int(end.timeIntervalSince(start) / 60))
    }

    /// A slim, auto-counting line: how long this routine has been going,
    /// plus the optional finish-by aim. Count-up only — no countdowns.
    /// Graphical step indicators — one mark per step. Done fills, skipped
    /// shows a small dash, current gets a ring. More than 8 steps collapses
    /// to a slim progress bar so the row can never overflow.
    private var stepDots: some View {
        Group {
            if stepCount > 8 {
                VStack(spacing: 6) {
                    KayaProgressBar(value: stepCount > 0
                                    ? Double(routine.completedCount) / Double(stepCount) : 0)
                        .padding(.horizontal, 40)
                    Text("\(routine.completedCount) of \(stepCount) done")
                        .font(.caption2)
                        .foregroundStyle(KayaTheme.subtleText)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(steps, id: \.order) { step in
                        stepDot(step)
                    }
                }
                .frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }

    private func stepDot(_ step: RoutineStepRecord) -> some View {
        let isCurrent = step.order == currentIndex
        return ZStack {
            if step.isDone {
                Circle().fill(KayaTheme.accent)
            } else if step.skipped {
                Circle().stroke(KayaTheme.subtleText.opacity(0.5), lineWidth: 1.5)
                    .overlay {
                        Rectangle()
                            .fill(KayaTheme.subtleText.opacity(0.5))
                            .frame(width: 5, height: 1.5)
                    }
            } else {
                Circle().fill(KayaTheme.warm)
            }
        }
        .frame(width: isCurrent ? 12 : 8, height: isCurrent ? 12 : 8)
        .overlay {
            if isCurrent && !step.isDone {
                Circle().stroke(KayaTheme.accent, lineWidth: 2)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6),
                   value: step.isDone)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6),
                   value: step.skipped)
    }

    /// The dominant count-up timer — it starts the moment the routine opens.
    private var bigTimer: some View {
        VStack(spacing: 2) {
            if let started = routine.startedAt {
                Text(started, style: .timer)
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(KayaTheme.accent)
                    .accessibilityLabel("Elapsed time, counting up")
            }
            Text(deadlineNote ?? remainingCaption)
                .font(.caption)
                .foregroundStyle(deadlineNote == nil ? KayaTheme.subtleText : KayaTheme.accent)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Completion

    private var completionView: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: checkAppeared ? 1 : 0)
                        .stroke(KayaTheme.success.opacity(0.5),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 108, height: 108)
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 84))
                        .foregroundStyle(KayaTheme.success)
                }
                    .padding(.top, 24)
                    .scaleEffect(checkAppeared || reduceMotion ? 1 : 0.3)
                    .opacity(checkAppeared ? 1 : 0)
                    .onAppear {
                        if !reduceMotion {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                                checkAppeared = true
                            }
                        } else {
                            checkAppeared = true
                        }
                    }
                    .accessibilityHidden(true)

                Text("You finished")
                    .font(.largeTitle.bold())
                    .foregroundStyle(KayaTheme.text)
                Text(routine.title)
                    .font(.title3)
                    .foregroundStyle(KayaTheme.subtleText)
                    .multilineTextAlignment(.center)
                Text("You did it your way, at your own pace.")
                    .font(.body)
                    .foregroundStyle(KayaTheme.subtleText)
                    .multilineTextAlignment(.center)
                if let minutes = finishMinutes {
                    Label("Finished in about \(minutes) min", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                }

            if !newMilestones.isEmpty {
                VStack(spacing: 10) {
                    ForEach(newMilestones) { milestone in
                        HStack(spacing: 12) {
                            Image(systemName: milestone.symbol)
                                .font(.title3)
                                .foregroundStyle(KayaTheme.onAccent)
                                .frame(width: 44, height: 44)
                                .background(KayaTheme.accent)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Milestone: \(milestone.title)")
                                    .font(.headline)
                                    .foregroundStyle(KayaTheme.text)
                                Text(milestone.detail)
                                    .font(.caption)
                                    .foregroundStyle(KayaTheme.subtleText)
                            }
                            Spacer()
                        }
                        .kayaCard(padding: 14)
                    }
                }
                .padding(.horizontal, 20)
            }

            reflectionSection.padding(.horizontal, 20)
            gentlerCard.padding(.horizontal, 20)
            photosSection.padding(.horizontal, 20)

            VStack(spacing: 12) {
                Button {
                    speech.stop()
                    dismiss()
                } label: {
                    Text("Back to home")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KayaPrimaryButtonStyle())

                Button {
                    announcedFinish = false
                    // A fresh run earns a fresh journal offer — these are
                    // per-finish, not per-view.
                    journalAsked = false
                    awaitingJournal = false
                    journalTask?.cancel()
                    RoutineStore.restart(routine, in: modelContext)
                    narrateCurrent()
                } label: {
                    Label("Do it again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KayaSecondaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        }
    }

    /// "How did that feel?" → difficulty choice, then Kaya writes a short
    /// on-device reflection about what they did.
    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let difficulty = routine.difficulty {
                Label("You said it felt \(difficulty.label.lowercased()).", systemImage: difficulty.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KayaTheme.accent)
                if reflectionLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(KayaTheme.accent)
                        Text("Kaya is thinking…")
                            .font(.caption)
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                } else if let reflection = routine.aiReflection {
                    Text(reflection)
                        .font(.body)
                        .foregroundStyle(KayaTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("How did that feel?")
                    .font(.headline)
                    .foregroundStyle(KayaTheme.text)
                HStack(spacing: 10) {
                    ForEach(DifficultyLevel.allCases, id: \.self) { level in
                        Button {
                            setDifficulty(level)
                        } label: {
                            Label(level.label, systemImage: level.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(KayaTheme.text)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(KayaTheme.warm)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .accessibilityHint("Kaya will write you a short message about it")
                    }
                }
                if handsFree {
                    Text("You can just say it — “easy”, “okay”, or “hard”.")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kayaCard()
    }

    /// When a routine felt hard, Kaya offers to rebuild it gentler for the
    /// next repeat — smaller steps, same goal, done on-device.
    @ViewBuilder
    private var gentlerCard: some View {
        if routine.difficulty == .hard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Next time can be easier", systemImage: "arrow.down.to.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KayaTheme.text)
                if gentlerApplied {
                    Text("Done — next time this routine has \(routine.sortedSteps.count) smaller steps.")
                        .font(.subheadline)
                        .foregroundStyle(KayaTheme.subtleText)
                } else {
                    Text("Kaya can make the steps smaller and add more support, keeping the same goal.")
                        .font(.subheadline)
                        .foregroundStyle(KayaTheme.subtleText)
                    Button {
                        applyGentlerVariant()
                    } label: {
                        HStack(spacing: 8) {
                            if gentlerWorking {
                                ProgressView().tint(KayaTheme.onAccent).controlSize(.small)
                            }
                            Text(gentlerWorking ? "Making it gentler…" : "Make it gentler for next time")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KayaTheme.accent)
                    .foregroundStyle(KayaTheme.onAccent)
                    .disabled(gentlerWorking)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kayaCard()
        }
    }

    /// Optional photo memories — stored locally, never uploaded.
    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("A photo of your result", systemImage: "camera")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KayaTheme.text)

            if !routine.photoData.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(routine.photoData.enumerated()), id: \.offset) { index, data in
                        VStack(spacing: 4) {
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            TextField("What is it?", text: captionBinding(for: index))
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .frame(width: 64)
                                .onSubmit { refreshReflectionIfWritten() }
                                .accessibilityLabel("Describe this photo — Kaya uses it in your message")
                        }
                    }
                }
            }

            if routine.photoData.count < 3 {
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: 3 - routine.photoData.count,
                    matching: .images
                ) {
                    Label(routine.photoData.isEmpty ? "Add a photo" : "Add another photo",
                          systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KayaTheme.accent)
                        .frame(minHeight: 44)
                }
            }

            Text("Photos stay on this device — Kaya never uploads them. A caption helps Kaya mention what you made.")
                .font(.caption2)
                .foregroundStyle(KayaTheme.subtleText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kayaCard()
    }

    /// Two-way binding into `photoCaptions`, padded to match the photos.
    private func captionBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { routine.photoCaptions.count > index ? routine.photoCaptions[index] : "" },
            set: { newValue in
                while routine.photoCaptions.count <= index { routine.photoCaptions.append("") }
                routine.photoCaptions[index] = newValue
                try? modelContext.save()
            }
        )
    }

    /// If Kaya already wrote the reflection, refresh it once a caption is
    /// added so the message can mention what the photo shows.
    private func refreshReflectionIfWritten() {
        guard routine.aiReflection != nil, routine.difficulty != nil else { return }
        requestReflection()
    }

    /// Per-step timing: real duration once it's done ("took about 6 min"),
    /// the estimate while pending ("about 5 min").
    @ViewBuilder
    private func stepTimingCaption(_ step: RoutineStepRecord) -> some View {
        if step.isDone, let seconds = step.lastDurationSeconds, seconds > 0 {
            let minutes = Int(round(Double(seconds) / 60))
            Text(minutes < 1 ? "took under a minute" : "took about \(minutes) min")
                .font(.caption2)
                .foregroundStyle(KayaTheme.subtleText)
        } else if step.estimatedMinutes > 0 {
            Text("about \(step.estimatedMinutes) min")
                .font(.caption2)
                .foregroundStyle(KayaTheme.subtleText)
        }
    }

    /// The whole routine at a glance — done steps checked, current step
    /// highlighted. Tapping an unfinished row jumps there and re-reads it.
    private var stepsOverviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(steps, id: \.order) { step in
                        let index = step.order
                        let isCurrent = index == currentIndex && !routine.isFinished
                        Button {
                            guard !step.isDone, index != currentIndex else { return }
                            showStepsOverview = false
                            step.skipped = false
                            routine.currentStepIndex = index
                            stepStartedAt = Date()
                            RoutineStore.touch(routine, in: modelContext)
                            // resumeAfterSheet re-narrates the step on dismiss.
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(step.isDone ? KayaTheme.success
                                              : isCurrent ? KayaTheme.accent : KayaTheme.warm)
                                        .frame(width: 30, height: 30)
                                    if step.isDone {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(KayaTheme.onAccent)
                                    } else {
                                        Text("\(index + 1)")
                                            .font(.caption.bold())
                                            .foregroundStyle(isCurrent ? KayaTheme.onAccent : KayaTheme.subtleText)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(step.isDone || step.skipped
                                                         ? KayaTheme.subtleText : KayaTheme.text)
                                        .strikethrough(step.isDone)
                                        .multilineTextAlignment(.leading)
                                    stepTimingCaption(step)
                                }
                                Spacer()
                                if isCurrent {
                                    Text("Now")
                                        .font(.caption2.bold())
                                        .foregroundStyle(KayaTheme.onAccent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(KayaTheme.accent))
                                } else if step.skipped && !step.isDone {
                                    Text("Skipped")
                                        .font(.caption2.bold())
                                        .foregroundStyle(KayaTheme.subtleText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(KayaTheme.warm))
                                } else if !step.isDone {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(KayaTheme.subtleText)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isCurrent ? KayaTheme.warm : KayaTheme.card)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(isCurrent ? KayaTheme.accent.opacity(0.5) : .clear,
                                                    lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(step.isDone)
                    }
                }
                .padding(16)
            }
            .background(KayaTheme.background.ignoresSafeArea())
            .navigationTitle("All steps")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Voice loop

    private func toggleHandsFree() {
        if handsFree {
            handsFree = false
            voice.stopListening()
            speech.stop()
            voiceNote = nil
            return
        }
        Task {
            guard await voice.enable() else {
                voiceNote = "Voice isn't available — tap the step card when it's done."
                return
            }
            handsFree = true
            voiceNote = nil
            if let profile, !profile.usedVoiceControl {
                profile.usedVoiceControl = true
                newMilestones += Momentum.checkNew(in: profile)
                try? modelContext.save()
            }
            narrateCurrent(prefix: "Hands-free on. ")
        }
    }

    /// Speak text, then go back to listening when hands-free is on.
    private func speakThenListen(_ text: String) {
        voice.stopListening()
        guard handsFree || routine.speakInstructions else { return }
        speech.speak(text, languageCode: routine.languageCode) { [self] in
            if handsFree, !routine.isFinished {
                voice.startListening()
            }
        }
    }

    private func narrateCurrent(prefix: String = "") {
        guard let step = currentStep else { return }
        let text = "\(prefix)Step \(currentIndex + 1) of \(stepCount). \(step.title). \(step.instruction)"
        if shouldSpeak {
            speakThenListen(text)
        } else if handsFree {
            voice.startListening()
        }
    }

    private func resumeAfterSheet() {
        guard handsFree, !routine.isFinished else { return }
        narrateCurrent()
    }

    private func handleTranscript() {
        guard handsFree else { return }
        let tail = voice.unhandled
        guard !tail.isEmpty else { return }
        if let command = VoiceCommands.parse(tail) {
            voice.markHandled()
            if routine.isFinished {
                switch command {
                case .feltEasy: setDifficulty(.easy)
                case .feltOkay: setDifficulty(.okay)
                case .feltHard: setDifficulty(.hard)
                case .stop: exitRoutine()
                case .overview: showStepsOverview = true
                default: break
                }
                return
            }
            execute(command)
            return
        }
        // Not a command — after finishing, an open answer is the journal;
        // mid-task, a question-shaped utterance gets a real answer.
        if routine.isFinished {
            guard awaitingJournal else { return }
            let snapshot = tail
            journalTask?.cancel()
            journalTask = Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled, voice.unhandled == snapshot else { return }
                captureJournal(snapshot)
            }
            return
        }
        guard !isPaused, !questionInFlight, let step = currentStep,
              looksLikeQuestion(tail) else { return }
        let snapshot = tail
        questionTask?.cancel()
        questionTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, voice.unhandled == snapshot else { return }
            answerStepQuestion(snapshot, about: step)
        }
    }

    /// English + Tagalog question shapes — "why", "how", "what does X mean",
    /// "bakit", "paano" — anything that isn't a command but asks something.
    private func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let starters = ["why ", "what ", "what's ", "whats ", "how ", "when ",
                        "where ", "can i", "could i", "do i ", "should i",
                        "is it ", "is this ", "bakit", "ano ", "anong ",
                        "paano", "saan", "kelan", "pwede ba", "okay lang ba"]
        return t.hasSuffix("?") || starters.contains(where: { t.hasPrefix($0) })
    }

    /// Answer a mid-step question via the local model, then re-narrate the
    /// step so the hands-free flow picks up where it left off.
    private func answerStepQuestion(_ question: String, about step: RoutineStepRecord) {
        guard !questionInFlight else { return }
        questionInFlight = true
        questionTask = nil
        voice.markHandled()
        voice.stopListening()
        voiceNote = "Thinking…"
        Task {
            let answer = try? await aiService.answerStepQuestion(
                step: step.title, instruction: step.instruction,
                routineTitle: routine.title, question: question, profile: profile
            )
            questionInFlight = false
            voiceNote = nil
            if let answer {
                speech.speak(answer, languageCode: routine.languageCode) { [self] in
                    narrateCurrent(prefix: "Back to the step. ")
                }
            } else {
                narrateCurrent(prefix: "I'm not sure about that one — here's the step again. ")
            }
        }
    }

    /// The post-finish journal: distill what the user said onto the routine,
    /// then acknowledge. Falls back to their raw words if the model's off.
    private func captureJournal(_ raw: String) {
        awaitingJournal = false
        journalTask = nil
        voice.markHandled()
        voice.stopListening()
        voiceNote = "Keeping that in mind…"
        Task {
            let note = try? await aiService.distillJournal(raw, routineTitle: routine.title)
            routine.lastUserNote = note
                ?? String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            try? modelContext.save()
            voiceNote = nil
            speakThenListen("Thanks — I'll keep that in mind for next time.")
        }
    }

    private func execute(_ command: VoiceCommand) {
        switch command {
        case .done, .next:
            markDoneAndAdvance()
        case .skip:
            // Skip means "move past it", not "it's done" — never count a
            // step the user didn't confirm.
            skipCurrentStep()
        case .previous:
            goToPrevious()
        case .repeatStep:
            repeatStep()
        case .overview:
            voice.stopListening()
            showStepsOverview = true
        case .pause:
            pauseRoutine()
        case .resume:
            if isPaused {
                isPaused = false
                narrateCurrent()
            }
        case .help:
            voice.stopListening()
            showHelp = true
        case .somethingChanged:
            voice.stopListening()
            showSomethingChanged = true
        case .stop:
            handsFree = false
            voice.stopListening()
            voiceNote = "Stopping. Your progress is saved."
            speech.speak("Okay. Stopping here. Your progress is saved.",
                         languageCode: routine.languageCode) { [self] in
                RoutineStore.touch(routine, in: modelContext)
                dismiss()
            }
        case .start:
            if isPaused { isPaused = false }
            narrateCurrent()
        case .simplify:
            simplifyCurrentStep()
        case .feltEasy, .feltOkay, .feltHard:
            break
        }
    }

    // MARK: - Actions

    private func markDoneAndAdvance() {
        guard let step = currentStep, !step.isDone else {
            // Already counted — just move forward.
            if !isLastStep {
                routine.currentStepIndex = currentIndex + 1
                RoutineStore.touch(routine, in: modelContext)
                narrateCurrent()
            }
            return
        }
        step.isDone = true
        step.skipped = false
        step.lastDurationSeconds = Int(Date().timeIntervalSince(stepStartedAt))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        var praise = ""
        if let profile {
            profile.stepsFinished += 1
            profile.noteActiveToday()
            newMilestones += Momentum.checkNew(in: profile)
            if profile.encouragement == .lots, !isLastStep {
                praise = Momentum.praise(for: profile.stepsFinished) + " "
                if !handsFree { voiceNote = praise.trimmingCharacters(in: .whitespaces) }
            }
        }

        if isLastStep {
            routine.isFinished = true
            routine.finishedAt = Date()
            routine.currentStepIndex = currentIndex
            // Capture the outcome before any restart clears the flags —
            // drives the "want a gentler version?" offer next run.
            routine.lastRunHadSkips = routine.steps.contains { $0.skipped }
            routine.gentlerOffered = false
        } else {
            routine.currentStepIndex = currentIndex + 1
            stepStartedAt = Date()
        }
        RoutineStore.touch(routine, in: modelContext)

        if !routine.isFinished {
            narrateCurrent(prefix: praise)
        }
    }

    private func goToPrevious() {
        guard currentIndex > 0 else {
            if handsFree { narrateCurrent(prefix: "This is the first step. ") }
            return
        }
        routine.currentStepIndex = currentIndex - 1
        stepStartedAt = Date()
        RoutineStore.touch(routine, in: modelContext)
        narrateCurrent()
    }

    private func skipCurrentStep() {
        currentStep?.skipped = true
        currentStep?.lastDurationSeconds = Int(Date().timeIntervalSince(stepStartedAt))
        guard !isLastStep else {
            routine.isFinished = true
            routine.finishedAt = Date()
            routine.lastRunHadSkips = routine.steps.contains { $0.skipped }
            routine.gentlerOffered = false
            RoutineStore.touch(routine, in: modelContext)
            return
        }
        routine.currentStepIndex = currentIndex + 1
        stepStartedAt = Date()
        RoutineStore.touch(routine, in: modelContext)
        narrateCurrent()
    }

    private func repeatStep() {
        guard let step = currentStep else { return }
        if shouldSpeak {
            speakThenListen("\(step.title). \(step.instruction)")
        }
    }

    private func pauseRoutine() {
        isPaused = true
        RoutineStore.touch(routine, in: modelContext)
        if handsFree {
            speakThenListen("Paused. Take your time. Say resume when you're ready.")
        }
    }

    private func exitRoutine() {
        handsFree = false
        voice.stopListening()
        speech.stop()
        RoutineStore.touch(routine, in: modelContext)
        dismiss()
    }

    // MARK: - Reflection & photos

    private func setDifficulty(_ level: DifficultyLevel) {
        guard routine.difficulty != level else { return }
        routine.difficulty = level
        if let profile {
            profile.reflectionsGiven += 1
            newMilestones += Momentum.checkNew(in: profile)
        }
        RoutineStore.touch(routine, in: modelContext)
        requestReflection()
    }

    private func requestReflection() {
        reflectionLoading = true
        let title = routine.title
        let count = stepCount
        let difficulty = routine.difficulty
        let photoCount = routine.photoData.count
        let profile = profile
        Task {
            let text = try? await aiService.reflectOnCompletion(
                routineTitle: title,
                stepCount: count,
                difficulty: difficulty,
                photoCount: photoCount,
                photoCaptions: routine.photoCaptions,
                profile: profile
            )
            routine.aiReflection = text ?? Self.fallbackReflection(for: difficulty)
            reflectionLoading = false
            try? modelContext.save()
            if shouldSpeak, let message = routine.aiReflection {
                speech.speak(message, languageCode: routine.languageCode) { [self] in
                    // One gentle, optional journal prompt — only hands-free,
                    // only once per finish. "Stop" still closes as usual.
                    guard handsFree, !journalAsked else { return }
                    journalAsked = true
                    awaitingJournal = true
                    speakThenListen("If you want, tell me how it went — a few words is enough. Or say stop to finish.")
                }
            }
        }
    }

    // MARK: - Adaptive steps

    /// Gentle once-per-step check-in: if the user has been on a step much
    /// longer than its AI estimate, quietly offer to break it down.
    private func checkPace() {
        guard !paceOffered, !isPaused, !routine.isFinished, !isEstimatingGentler,
              let step = currentStep, step.estimatedMinutes > 0 else { return }
        let elapsed = Date().timeIntervalSince(stepStartedAt)
        guard elapsed > Double(step.estimatedMinutes) * 120 else { return }
        paceOffered = true
        voiceNote = "Still on this step? Say “simpler” and I'll break it down."
        if shouldSpeak {
            speakThenListen("You're still on this step — that's okay. If it's a lot, say “simpler” and I'll break it down.")
        }
    }

    /// "Say it simpler" / "break it down" — the model splits the step into
    /// micro-steps inserted live, or rewrites the instruction plainer.
    private func simplifyCurrentStep() {
        guard !simplifyInFlight, let step = currentStep else { return }
        simplifyInFlight = true
        voiceNote = "Making this step easier…"
        let title = step.title
        let instruction = step.instruction
        let routineTitle = routine.title
        let userProfile = profile
        Task {
            if let micro = try? await aiService.breakDownStep(
                title: title, instruction: instruction,
                routineTitle: routineTitle, profile: userProfile
            ), micro.count > 1 {
                insertMicroSteps(micro, after: step)
                simplifyInFlight = false
                voiceNote = nil
                narrateCurrent(prefix: "Made it smaller. ")
                return
            }
            if let simpler = try? await aiService.simplifyStep(
                title: title, instruction: instruction, profile: userProfile
            ) {
                step.instruction = simpler
                try? modelContext.save()
                simplifyInFlight = false
                voiceNote = nil
                narrateCurrent(prefix: "Simpler version. ")
                return
            }
            simplifyInFlight = false
            voiceNote = nil
            narrateCurrent(prefix: "Here's the step again. ")
        }
    }

    /// Replace the current step with smaller ones — it counts as covered by
    /// the breakdown rather than marked done directly.
    private func insertMicroSteps(_ texts: [String], after origin: RoutineStepRecord) {
        origin.isDone = true
        let originOrder = origin.order
        for record in routine.steps where record.order > originOrder {
            record.order += texts.count
        }
        for (offset, text) in texts.enumerated() {
            let record = RoutineStepRecord(
                title: text,
                instruction: "",
                doneDescription: "",
                symbolName: origin.symbolName,
                order: originOrder + 1 + offset,
                estimatedMinutes: 0
            )
            routine.steps.append(record)
        }
        routine.currentStepIndex = currentIndex + 1
        stepStartedAt = Date()
        RoutineStore.touch(routine, in: modelContext)
    }

    /// After a routine "felt hard", offer to rebuild it gentler for the
    /// next time — same goal, smaller steps, more support.
    private func applyGentlerVariant() {
        guard !gentlerWorking else { return }
        gentlerWorking = true
        Task {
            if let gentler = try? await aiService.gentlerVariant(routine: routine, profile: profile) {
                for step in routine.steps { modelContext.delete(step) }
                routine.steps = []
                for (index, step) in gentler.steps.enumerated() {
                    let record = RoutineStepRecord(
                        title: step.title,
                        instruction: step.instruction,
                        doneDescription: step.doneDescription,
                        symbolName: step.symbolName,
                        order: index,
                        estimatedMinutes: step.estimatedMinutes
                    )
                    routine.steps.append(record)
                }
                try? modelContext.save()
                gentlerApplied = true
                voiceNote = "Made it gentler — same goal, smaller steps."
            } else {
                voiceNote = nil
            }
            gentlerWorking = false
        }
    }

    private var isEstimatingGentler: Bool { gentlerWorking }

    // MARK: - "You'll need…" briefing

    @State private var preparedItems: [String] = []
    @State private var itemsAnnounced = false

    /// Ask the model what the steps imply the user needs, then mention it
    /// once before the first step — only if still on step one.
    private func loadPreparedItems() {
        let title = routine.title
        let summaries = routine.sortedSteps.map { "\($0.title): \($0.instruction)" }
        Task {
            guard let items = try? await aiService.prepareItems(
                routineTitle: title, stepSummaries: summaries
            ), !items.isEmpty else { return }
            preparedItems = items
            if !itemsAnnounced, shouldSpeak, currentIndex == 0, routine.completedCount == 0 {
                itemsAnnounced = true
                voiceNote = "You'll need: \(items.joined(separator: ", "))"
                speakThenListen("Before you start, you'll need: \(items.joined(separator: ", ")).")
            }
        }
    }

    private static func fallbackReflection(for difficulty: DifficultyLevel?) -> String {
        switch difficulty {
        case .hard:
            return "You finished something that felt hard — every step took real effort, and you did it."
        case .okay:
            return "You worked through every step and finished. That counts."
        case .easy:
            return "You finished smoothly. This is a routine you can rely on."
        case nil:
            return "You finished every step. You did it your way, at your own pace."
        }
    }

    private func loadPickedPhotos() {
        let items = pickedItems
        guard !items.isEmpty else { return }
        pickedItems = []
        Task {
            var addedAny = false
            for item in items {
                guard routine.photoData.count < 3 else { break }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.6) {
                    routine.photoData.append(jpeg)
                    addedAny = true
                }
            }
            if addedAny, let profile {
                profile.photosAdded += 1
                newMilestones += Momentum.checkNew(in: profile)
            }
            try? modelContext.save()
        }
    }
}
