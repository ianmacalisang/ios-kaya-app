//
//  HelpView.swift
//  Kaya
//
//  Ready-to-show help messages and "Something changed" assistance.
//

import SwiftData
import SwiftUI

// MARK: - Help

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var speech = SpeechService()

    let onStopRoutine: () -> Void
    var languageCode: String = "en"

    @State private var selectedMessage: String?
    @State private var confirmStop = false

    private static let messages: [(text: String, icon: String)] = [
        ("Please explain that another way.", "text.bubble"),
        ("I need a break.", "pause.circle"),
        ("I need help from someone.", "hand.raised"),
        ("I want to stop this routine.", "stop.circle")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                KayaTheme.background.ignoresSafeArea()

                if let message = selectedMessage {
                    helpCard(message)
                } else {
                    messageList
                }
            }
            .navigationTitle(selectedMessage == nil ? "I need help" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if selectedMessage != nil {
                            selectedMessage = nil
                        } else {
                            speech.stop()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: selectedMessage == nil ? "xmark" : "chevron.left")
                            .font(.body.bold())
                            .foregroundStyle(KayaTheme.text)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(selectedMessage == nil ? "Close help" : "Back to messages")
                }
            }
            .confirmationDialog("Stop this routine?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the routine", role: .destructive) {
                    speech.stop()
                    dismiss()
                    onStopRoutine()
                }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Your progress is saved. You can come back anytime.")
            }
        }
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tap a message to show it in large text. You can hold it up or say it to someone.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .padding(.horizontal, 20)

            ForEach(Self.messages, id: \.text) { message in
                Button {
                    if message.text == "I want to stop this routine." {
                        confirmStop = true
                    } else {
                        selectedMessage = message.text
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: message.icon)
                            .font(.title3)
                            .foregroundStyle(KayaTheme.accent)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        Text(message.text)
                            .font(.headline)
                            .foregroundStyle(KayaTheme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                    .kayaCard(padding: 18)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private func helpCard(_ message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Text(message)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(KayaTheme.text)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)

            Button {
                speech.speak(message, languageCode: languageCode)
            } label: {
                Label("Say it aloud", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KayaSecondaryButtonStyle())
            .padding(.horizontal, 24)
            Spacer()
            Text("You can show this screen to someone near you.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .padding(.bottom, 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - Something changed

struct SomethingChangedView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @State private var aiService = LocalAIService()

    let routineTitle: String
    let stepTitle: String
    let onSkipStep: () -> Void
    let onPause: () -> Void
    let onGetHelp: () -> Void

    @State private var selectedSituation: String?
    @State private var suggestions: [String] = []
    @State private var isLoading = false

    private static let situations: [(text: String, icon: String)] = [
        ("The item is unavailable", "bag.badge.questionmark"),
        ("The place is closed", "storefront"),
        ("I forgot something", "questionmark.circle"),
        ("I don't understand this step", "text.bubble")
    ]

    private static let fallbackSuggestions: [String: [String]] = [
        "The item is unavailable": ["Choose a similar item instead.", "Skip it for now and get it another day.", "Ask a staff member where else to find it."],
        "The place is closed": ["Come back another time.", "Look for another place nearby that is open.", "Ask someone you trust for another option."],
        "I forgot something": ["Decide if you can continue without it.", "Go back and get it if that feels okay.", "Ask someone to bring it or help."],
        "I don't understand this step": ["Read the step again slowly.", "Try repeating the instruction aloud.", "Ask someone nearby to explain it."]
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                KayaTheme.background.ignoresSafeArea()

                if selectedSituation == nil {
                    situationList
                } else {
                    suggestionList
                }
            }
            .navigationTitle("Something changed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if selectedSituation != nil {
                            selectedSituation = nil
                            suggestions = []
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: selectedSituation == nil ? "xmark" : "chevron.left")
                            .font(.body.bold())
                            .foregroundStyle(KayaTheme.text)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(selectedSituation == nil ? "Close" : "Back")
                }
            }
        }
    }

    private var situationList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What changed? Pick the closest one — that's okay if it's not exact.")
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
                .padding(.horizontal, 20)

            ForEach(Self.situations, id: \.text) { situation in
                Button {
                    select(situation.text)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: situation.icon)
                            .font(.title3)
                            .foregroundStyle(KayaTheme.accent)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        Text(situation.text)
                            .font(.headline)
                            .foregroundStyle(KayaTheme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                    .kayaCard(padding: 18)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().tint(KayaTheme.accent)
                        Text("Thinking on this device…")
                            .font(.subheadline)
                            .foregroundStyle(KayaTheme.subtleText)
                    }
                    .frame(maxWidth: .infinity)
                    .kayaCard()
                    .padding(.horizontal, 20)
                } else {
                    Text("Here are some things you could do:")
                        .font(.headline)
                        .foregroundStyle(KayaTheme.text)
                        .padding(.horizontal, 20)

                    ForEach(suggestions, id: \.self) { suggestion in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(KayaTheme.accent)
                                .accessibilityHidden(true)
                            Text(suggestion)
                                .font(.body)
                                .foregroundStyle(KayaTheme.text)
                            Spacer()
                        }
                        .kayaCard(padding: 16)
                        .padding(.horizontal, 20)
                    }

                    Text("Or choose an action:")
                        .font(.headline)
                        .foregroundStyle(KayaTheme.text)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                            onSkipStep()
                        } label: {
                            Label("Skip this step", systemImage: "forward.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KayaSecondaryButtonStyle())

                        Button {
                            dismiss()
                            onGetHelp()
                        } label: {
                            Label("I need help", systemImage: "hand.raised.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KayaSecondaryButtonStyle())

                        Button {
                            dismiss()
                            onPause()
                        } label: {
                            Label("Pause this routine", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KayaSecondaryButtonStyle())
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func select(_ situation: String) {
        selectedSituation = situation
        isLoading = true

        Task {
            if let generated = try? await aiService.suggestAlternatives(
                situation: situation,
                stepTitle: stepTitle,
                routineTitle: routineTitle,
                profile: profiles.first
            ) {
                suggestions = generated
            } else {
                suggestions = Self.fallbackSuggestions[situation] ?? []
            }
            isLoading = false
        }
    }
}
