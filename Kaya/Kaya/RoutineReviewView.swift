//
//  RoutineReviewView.swift
//  Kaya
//
//  Review and edit a routine before starting it. Nothing starts automatically.
//

import SwiftData
import SwiftUI

struct RoutineReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var draft: RoutineDraft
    @State private var startedRoutine: Routine?
    @State private var voice = VoiceService()
    @State private var speech = SpeechService()
    @State private var aiService = LocalAIService()
    @State private var announcedSummary = false
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(60 * 60)
    @State private var paceNote: String?
    @State private var paceLoading = false
    @State private var paceTask: Task<Void, Never>?

    private var profile: UserProfile? { profiles.first }

    init(draft: RoutineDraft) {
        _draft = State(initialValue: draft)
    }

    private var hasSteps: Bool {
        draft.steps.contains {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                || !$0.instruction.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if draft.generatedByAI {
                    Label("Made by on-device AI — you can edit anything", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                }

                titleSection
                deadlineCard
                stepsSection

                Button {
                    draft.steps.append(StepDraft(
                        title: "", instruction: "", doneDescription: "",
                        symbolName: "checkmark.circle"
                    ))
                } label: {
                    Label("Add a step", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KayaSecondaryButtonStyle())

                VStack(spacing: 10) {
                    VoiceOrb(isListening: voice.isListening, isSpeaking: speech.isSpeaking, size: 56) {
                        toggleVoice()
                    }
                    .frame(height: 80)
                    Text(voice.isListening
                         ? "Listening… say “start”, “read steps”, or “back”."
                         : "Tap the mic, or use the buttons below.")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    Button {
                        startRoutine()
                    } label: {
                        Label("Start this routine", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KayaPrimaryButtonStyle())
                    .disabled(!hasSteps)
                    .opacity(hasSteps ? 1 : 0.5)

                    Button {
                        RoutineStore.save(draft, in: modelContext)
                        dismiss()
                    } label: {
                        Text("Save for later")
                            .font(.subheadline)
                            .foregroundStyle(KayaTheme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .disabled(!hasSteps)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(KayaTheme.background.ignoresSafeArea())
        .navigationTitle("Review your routine")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $startedRoutine) { routine in
            GuidedTaskView(routine: routine)
        }
        .onAppear {
            voice.onTranscript = handleTranscript
            hasDeadline = draft.deadline != nil
            if let existing = draft.deadline { deadline = existing }
            updatePaceNote()
            if draft.speakInstructions, !announcedSummary {
                announcedSummary = true
                speech.speak("Your routine has \(draft.steps.count) steps. Say start to begin, or edit anything below.",
                             languageCode: draft.languageCode)
            }
        }
        .onDisappear {
            voice.stopListening()
            speech.stop()
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routine name")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)
            TextField("Name your routine", text: $draft.title)
                .font(.body)
                .padding(14)
                .background(KayaTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(KayaTheme.warm, lineWidth: 2)
                )
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steps")
                .font(.headline)
                .foregroundStyle(KayaTheme.text)

            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, _ in
                VStack(spacing: 8) {
                    StepEditRow(step: $draft.steps[index])
                    stepControls(index: index)
                }
            }
        }
    }

    private func stepControls(index: Int) -> some View {
        HStack(spacing: 20) {
            Spacer()
            Button {
                moveStep(from: index, to: index - 1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(index == 0)
            .accessibilityLabel("Move step \(index + 1) up")

            Button {
                moveStep(from: index, to: index + 1)
            } label: {
                Label("Move down", systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(index == draft.steps.count - 1)
            .accessibilityLabel("Move step \(index + 1) down")

            Button(role: .destructive) {
                draft.steps.remove(at: index)
            } label: {
                Label("Delete step", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(.red.opacity(0.8))
            .accessibilityLabel("Delete step \(index + 1)")
        }
        .foregroundStyle(KayaTheme.accent)
        .padding(.horizontal, 8)
    }

    private func moveStep(from: Int, to: Int) {
        guard to >= 0, to < draft.steps.count else { return }
        let step = draft.steps.remove(at: from)
        draft.steps.insert(step, at: to)
    }

    // MARK: - Deadline card

    private var deadlineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Finish-by time", isOn: Binding(
                get: { hasDeadline },
                set: { newValue in
                    hasDeadline = newValue
                    draft.deadline = newValue ? deadline : nil
                    updatePaceNote()
                }
            ))
            .font(.subheadline.weight(.semibold))
            .toggleStyle(SwitchToggleStyle(tint: KayaTheme.accent))

            if hasDeadline {
                DatePicker("Finish by", selection: Binding(
                    get: { deadline },
                    set: { newValue in
                        deadline = newValue
                        draft.deadline = newValue
                        updatePaceNote()
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)
                .tint(KayaTheme.accent)

                if paceLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(KayaTheme.accent)
                        Text("Checking how the steps fit…")
                            .font(.caption)
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                } else if let paceNote {
                    Label(paceNote, systemImage: "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .kayaCard()
        .accessibilityElement(children: .combine)
    }

    private var totalEstimatedMinutes: Int {
        draft.steps.map(\.estimatedMinutes).reduce(0, +)
    }

    private func updatePaceNote() {
        paceTask?.cancel()
        guard let deadline = draft.deadline else {
            paceNote = nil
            paceLoading = false
            return
        }
        let minutes = totalEstimatedMinutes
        paceLoading = true
        paceTask = Task {
            let note = try? await aiService.paceCheck(
                totalMinutes: minutes,
                stepCount: draft.steps.count,
                deadline: deadline,
                profile: profile
            )
            guard !Task.isCancelled else { return }
            paceNote = note ?? Self.localPaceNote(totalMinutes: minutes, deadline: deadline)
            paceLoading = false
        }
    }

    private static func localPaceNote(totalMinutes: Int, deadline: Date) -> String {
        let remaining = Int(deadline.timeIntervalSinceNow / 60)
        if remaining <= 0 {
            return "That time has already passed — pick a new one if you still want a finish-by time."
        }
        if totalMinutes <= remaining {
            return "About \(totalMinutes) min of steps. You have about \(remaining) min — plenty of room."
        }
        return "About \(totalMinutes) min of steps for about \(remaining) min — a bit tight. You could trim a step if you like."
    }

    // MARK: - Actions

    private func startRoutine() {
        voice.stopListening()
        speech.stop()
        let routine = RoutineStore.save(draft, in: modelContext)
        startedRoutine = routine
    }

    // MARK: - Voice

    private func toggleVoice() {
        if voice.isListening {
            voice.stopListening()
            return
        }
        Task {
            guard await voice.enable() else { return }
            voice.startListening()
        }
    }

    private func handleTranscript() {
        let tail = voice.unhandled
        guard !tail.isEmpty, let command = VoiceCommands.parse(tail) else { return }
        voice.markHandled()
        switch command {
        case .start, .done, .next:
            startRoutine()
        case .repeatStep:
            speech.speak(stepSummary, languageCode: draft.languageCode) {
                self.voice.startListening()
            }
        case .previous, .stop:
            voice.stopListening()
            dismiss()
        default:
            break
        }
    }

    private var stepSummary: String {
        let titles = draft.steps.enumerated().map { "Step \($0.offset + 1). \($0.element.title)" }
        return (["Your routine has \(draft.steps.count) steps."] + titles).joined(separator: ". ")
    }
}

// MARK: - Editable step row

private struct StepEditRow: View {
    @Binding var step: StepDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Step name", text: $step.title)
                .font(.headline)
                .accessibilityLabel("Step name")
            TextField("What to do", text: $step.instruction, axis: .vertical)
                .font(.body)
                .accessibilityLabel("Instruction")
            TextField("Done when… (optional)", text: $step.doneDescription)
                .font(.caption)
                .foregroundStyle(KayaTheme.subtleText)
                .accessibilityLabel("How you know the step is done")
            Stepper("About \(step.estimatedMinutes) min", value: $step.estimatedMinutes, in: 0...120)
                .font(.caption)
                .foregroundStyle(KayaTheme.subtleText)
                .accessibilityLabel("Estimated minutes for this step")
        }
        .kayaCard(padding: 16)
    }
}
