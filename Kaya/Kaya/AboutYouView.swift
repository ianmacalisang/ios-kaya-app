//
//  AboutYouView.swift
//  Kaya
//
//  The You tab: your saved answers that guide the on-device AI,
//  plus edit and delete controls. Everything stays on-device.
//

import SwiftData
import SwiftUI

struct AboutYouView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]

    @State private var showEdit = false
    @State private var reminders = ReminderService.shared
    @AppStorage(ReminderService.enabledKey) private var remindersEnabled = true
    @AppStorage("kaya.speakReplies") private var speakReplies = true

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let profile {
                        answerCards(profile)
                        if !profile.learnedFacts.isEmpty {
                            learnedFactsCard(profile)
                        }
                        speakRepliesRow
                        reminderRow
                    } else {
                        ContentUnavailableView(
                            "No profile yet",
                            systemImage: "person.crop.circle",
                            description: Text("Answer a few questions so Kaya's on-device AI can shape tasks for you.")
                        )
                        .padding(.top, 60)
                    }

                    Button {
                        showEdit = true
                    } label: {
                        Text(profile == nil ? "Answer a few questions" : "Update my answers")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KayaPrimaryButtonStyle())

                    Label("Kaya's AI reads these answers every time it helps you. They never leave this device.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(KayaTheme.subtleText)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(KayaTheme.background.ignoresSafeArea())
            .navigationTitle("About you")
            // Refresh permission state when returning from Settings.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reminders.refreshStatus() }
            }
            .onChange(of: remindersEnabled) { _, on in
                if !on { reminders.clearAll() }
            }
            .fullScreenCover(isPresented: $showEdit) {
                OnboardingView(existing: profile)
            }
        }
    }

    @ViewBuilder
    private func answerCards(_ profile: UserProfile) -> some View {
        if !profile.name.isEmpty {
            answerRow("Name", value: profile.name, symbol: "person.fill")
        }
        answerRow("Step size", value: profile.stepSize.label, symbol: "list.number")
        if !profile.commonGoalsText.isEmpty {
            answerRow("Does often", value: profile.commonGoalsText, symbol: "star.fill")
        }
        if !profile.hardThingsText.isEmpty {
            answerRow("Hard things", value: profile.hardThingsText, symbol: "exclamationmark.triangle.fill")
        }
        if !profile.helpfulThingsText.isEmpty {
            answerRow("What helps", value: profile.helpfulThingsText, symbol: "heart.fill")
        }
        answerRow("Encouragement", value: profile.encouragement.label, symbol: "speaker.wave.2.fill")
        if !profile.extraContext.isEmpty {
            answerRow("Notes", value: profile.extraContext, symbol: "note.text")
        }
    }

    /// Facts Kaya remembered from conversation — user-confirmed, removable.
    /// The user owns what the app knows about them.
    private func learnedFactsCard(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.accent)
                    .frame(width: 28)
                Text("Things Kaya learned")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
                Spacer()
            }
            ForEach(profile.learnedFacts, id: \.self) { fact in
                HStack(spacing: 8) {
                    Text(fact)
                        .font(.subheadline)
                        .foregroundStyle(KayaTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        profile.learnedFacts.removeAll { $0 == fact }
                        try? modelContext.save()
                        Task { await redistill(profile) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Forget \(fact)")
                }
            }
        }
        .kayaCard(padding: 14)
        .accessibilityElement(children: .contain)
    }

    /// Re-distill the AI context after facts change.
    private func redistill(_ profile: UserProfile) async {
        if let summary = try? await LocalAIService().distillProfile(profile: profile) {
            profile.aiContextSummary = summary
            try? modelContext.save()
        }
    }

    /// Kaya reads her chat replies aloud. On by default — the whole app is
    /// voice-first — but easy to silence for quiet spaces.
    private var speakRepliesRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kaya's voice")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
                Text("Read chat replies aloud.")
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Kaya speaks replies", isOn: $speakReplies)
                .labelsHidden()
                .tint(KayaTheme.accent)
        }
        .kayaCard(padding: 14)
        .accessibilityElement(children: .contain)
    }

    /// Reminders opt-in — a gentle nudge at scheduled routine times.
    /// Mirrors iOS permission state honestly: denied means Settings.
    @ViewBuilder
    private var reminderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reminders")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
                Text("A gentle nudge when a routine is planned.")
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch reminders.authorization {
            case .authorized:
                Toggle("Reminders", isOn: $remindersEnabled)
                    .labelsHidden()
                    .tint(KayaTheme.accent)
            case .denied:
                Button("Off — open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.accent)
            default:
                Button("Turn on") {
                    Task { await reminders.requestPermission() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(KayaTheme.accent)
            }
        }
        .kayaCard(padding: 14)
        .accessibilityElement(children: .contain)
    }

    private func answerRow(_ label: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(KayaTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .kayaCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}
