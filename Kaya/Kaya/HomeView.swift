//
//  HomeView.swift
//  Kaya
//
//  The voice home: a greeting and one big press-to-talk orb.
//  Everything else lives in the other tabs.
//

import SwiftData
import SwiftUI

/// Where a voice request can take the user.
enum VoiceRoute: Hashable {
    case builder(goal: String, autoGenerate: Bool)
    case review(RoutineDraft)
}

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Routine.lastActivityAt, order: .reverse) private var routines: [Routine]
    @Query private var profiles: [UserProfile]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profile: UserProfile? { profiles.first }

    /// One line in the Kaya conversation panel.
    struct ChatEntry: Identifiable {
        let id = UUID()
        let isKaya: Bool
        var text: String
    }

    @State private var activeRoutine: Routine?
    @State private var voice = VoiceService()
    @State private var speech = SpeechService()
    /// When on, Kaya reads her chat replies aloud. Toggle lives in You.
    @AppStorage("kaya.speakReplies") private var speakReplies = true
    @State private var voiceRoute: VoiceRoute?
    @State private var heardText = ""
    @State private var autoRouteTask: Task<Void, Never>?
    /// Live pull distance while the chat is being dragged closed.
    @State private var chatDragOffset: CGFloat = 0
    @State private var orbAppeared = false
    @State private var showConversation = false
    @State private var conversation: [ChatEntry] = []
    @State private var aiService = LocalAIService()
    @State private var pendingDraft: RoutineDraft?
    @State private var pendingGoal = ""
    @State private var isGenerating = false
    @State private var pendingQuestion: PendingQuestion = .none
    @State private var briefing: String?
    /// One-shot escape hatch: when the model says a reply was an "answer",
    /// the exact parsers take it — but only once, so an "answer" verdict can
    /// never loop back into the model for the same utterance.
    @State private var forceKeywordOnce = false
    /// A durable fact the model heard, waiting on the user's yes/no — Kaya
    /// never remembers anything without asking first.
    @State private var pendingFact: String?
    /// Facts the user declined this session — never re-asked.
    @State private var declinedFacts = Set<String>()
    /// Set when the user taps the orb while Kaya is still speaking — the
    /// mic comes up as soon as she finishes instead of the tap being lost.
    @State private var micRequestedAfterSpeech = false
    /// Bumped every time the chat closes — a deferred action from
    /// `respondThen` only fires while its conversation is still open.
    @State private var conversationEpoch = 0

    /// Which scheduling question Kaya is waiting on, if any.
    private enum PendingQuestion {
        case none, repeatRule, scheduleTime, rememberFact
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KayaTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                        .padding(.top, showConversation ? 10 : 24)

                    if showConversation {
                        // The mic stays the hero — large enough to fill the
                        // space above the slim chat strip.
                        VStack(spacing: 4) {
                            VoiceOrb(isListening: voice.isListening, isSpeaking: speech.isSpeaking, size: 96) {
                                toggleVoice()
                            }
                            Text(voice.isListening
                                 ? "Listening… keep talking, I'm right here."
                                 : speech.isSpeaking
                                    ? "Kaya is speaking… tap the mic to interrupt."
                                    : "Tap to answer — or pick a suggestion below.")
                                .font(.caption)
                                .foregroundStyle(KayaTheme.subtleText)
                        }
                        .padding(.top, 6)
                        .frame(maxHeight: .infinity)
                        .gesture(closeDrag)

                        conversationPanel
                            // Anchored to the bottom, messenger-style —
                            // the newest exchange is always near the chips.
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.top, 8)
                            .transition(reduceMotion ? .opacity
                                        : .move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Spacer()

                        // The press-to-talk orb — the whole point of this screen.
                        VStack(spacing: 20) {
                            ZStack {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [KayaTheme.accent.opacity(0.22), .clear],
                                            center: .center,
                                            startRadius: 20,
                                            endRadius: 150
                                        )
                                    )
                                    .frame(width: 300, height: 300)
                                    .scaleEffect(orbAppeared && !reduceMotion ? 1.05 : 1.0)
                                    .animation(
                                        reduceMotion ? nil
                                            : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                                        value: orbAppeared
                                    )
                                    .allowsHitTesting(false)

                                VoiceOrb(isListening: voice.isListening, isSpeaking: speech.isSpeaking, size: 120) {
                                    toggleVoice()
                                }
                            }
                            .scaleEffect(orbAppeared || reduceMotion ? 1 : 0.6)
                            .opacity(orbAppeared ? 1 : 0)
                            .onAppear {
                                if !reduceMotion {
                                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                                        orbAppeared = true
                                    }
                                } else {
                                    orbAppeared = true
                                }
                            }

                            Text(voice.isListening ? "Listening…" : "Press to talk")
                                .font(.title2.bold())
                                .foregroundStyle(KayaTheme.text)

                            Text(voiceCaption)
                                .font(.subheadline)
                                .foregroundStyle(KayaTheme.subtleText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            if !heardText.isEmpty {
                                Text("Heard: \(heardText)")
                                    .font(.callout)
                                    .foregroundStyle(KayaTheme.accent)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }

                            if voice.permissionDenied || voice.isUnsupported {
                                NavigationLink {
                                    RoutineBuilderView()
                                } label: {
                                    Text("Type a goal instead")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(KayaTheme.accent)
                                        .frame(minHeight: 44)
                                }
                            }
                        }

                        Spacer()

                        if let briefing {
                            briefingCard(briefing)
                        }
                        todayChips

                        Label("Works offline. Everything stays on this device.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(KayaTheme.subtleText)
                            .padding(.bottom, 20)
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                       value: showConversation)
            .fullScreenCover(item: $activeRoutine) { routine in
                GuidedTaskView(routine: routine)
            }
            .navigationDestination(item: $voiceRoute) { route in
                switch route {
                case .builder(let goal, let autoGenerate):
                    RoutineBuilderView(initialGoal: goal, autoGenerate: autoGenerate)
                case .review(let draft):
                    RoutineReviewView(draft: draft)
                }
            }
            #if DEBUG
            .navigationDestination(item: $demoDraft) { draft in
                RoutineReviewView(draft: draft)
            }
            .navigationDestination(isPresented: $demoShowBuilder) {
                RoutineBuilderView()
            }
            .task {
                switch ProcessInfo.processInfo.environment["KAYA_DEMO_SCREEN"] {
                case "builder":
                    demoShowBuilder = true
                case "review":
                    demoDraft = RoutineStore.templates[0]
                case "deadline":
                    var draft = RoutineStore.templates[0]
                    draft.deadline = Date().addingTimeInterval(45 * 60)
                    demoDraft = draft
                case "done":
                    let routine = RoutineStore.save(RoutineStore.templates[0], in: modelContext)
                    routine.isFinished = true
                    routine.startedAt = Date()
                    activeRoutine = routine
                case "task":
                    let routine = RoutineStore.save(RoutineStore.templates[0], in: modelContext)
                    routine.speakInstructions = false
                    activeRoutine = routine
                case "taskskip":
                    // Mid-run with a done + a skipped step — verifies the
                    // step-dot truth states (fill / hollow-dash / ring).
                    let routine = RoutineStore.save(RoutineStore.templates[0], in: modelContext)
                    routine.speakInstructions = false
                    routine.startedAt = Date()
                    let steps = routine.sortedSteps
                    steps[0].isDone = true
                    steps[0].lastDurationSeconds = 240
                    steps[1].skipped = true
                    steps[1].lastDurationSeconds = 30
                    routine.currentStepIndex = 2
                    activeRoutine = routine
                case "chat":
                    showConversation = true
                    conversation = [
                        ChatEntry(isKaya: true, text: "Tell me a goal or a routine name — I'll take it from there."),
                        ChatEntry(isKaya: false, text: "I want to make lunch"),
                        ChatEntry(isKaya: true, text: "Done — \u{201C}Making a Simple Lunch\u{201D} has 5 steps."),
                        ChatEntry(isKaya: true, text: "Should it repeat? Say \u{201C}just once\u{201D}, \u{201C}every day\u{201D}, or \u{201C}Mondays\u{201D}.")
                    ]
                    pendingDraft = RoutineStore.templates[0]
                    pendingQuestion = .repeatRule
                case "hardroutine":
                    // Last run felt hard — shows the gentler-version banner.
                    let routine = RoutineStore.save(RoutineStore.templates[0], in: modelContext)
                    routine.speakInstructions = false
                    routine.difficulty = .hard
                    routine.lastRunHadSkips = true
                    activeRoutine = routine
                case "learn":
                    // Kaya heard a durable fact — shows the remember chips.
                    showConversation = true
                    conversation = [
                        ChatEntry(isKaya: true, text: "Tell me a goal or a routine name — I'll take it from there."),
                        ChatEntry(isKaya: false, text: "I work night shifts"),
                        ChatEntry(isKaya: true, text: "Want me to remember that — \u{201C}works night shifts\u{201D}? You can remove it anytime in You.")
                    ]
                    pendingFact = "works night shifts"
                    pendingQuestion = .rememberFact
                default:
                    break
                }
            }
            #endif
            .onDisappear {
                autoRouteTask?.cancel()
                voice.stopListening()
                speech.stop()
            }
            .task {
                // Chat turns the mic off when nobody's using it — 25s of
                // silence is generous enough to gather a thought, then it sleeps.
                voice.idleTimeoutSeconds = 25
                await loadBriefing()
            }
            .onChange(of: routines.count) { _, _ in
                Task { await loadBriefing() }
            }
            .onChange(of: dueToday.map(\.id)) { _, _ in
                Task { await loadBriefing() }
            }
        }
    }

    #if DEBUG
    @State private var demoDraft: RoutineDraft?
    @State private var demoShowBuilder = false
    #endif

    // MARK: - Header

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        let name = profile?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? part : "\(part), \(name)"
    }

    /// The line under the greeting — aware of the day. Mid-run routines and
    /// things planned take priority; otherwise a gentle phrase rotates daily
    /// so the screen keeps feeling alive. Calm, never pushy.
    private var tagline: String {
        if let active = routines.first(where: { !$0.isFinished && $0.completedCount > 0 }) {
            return "You're partway through \u{201C}\(active.title)\u{201D} — pick up whenever."
        }
        switch dueToday.count {
        case 1:
            return "One thing planned for today — whenever you're ready."
        case let n where n > 1:
            return "\(n) things planned today — one at a time."
        default:
            let lines = [
                "Your goals. Your pace. Your independence.",
                "One small step at a time.",
                "Whatever's next, we'll take it gently.",
                "No rush — I'm here when you're ready.",
                "Say a goal, and we'll make it smaller.",
                "Kaya means \u{201C}can\u{201D} — and you can."
            ]
            let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
            return lines[day % lines.count]
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(greeting)
                .font(.title.bold())
                .foregroundStyle(KayaTheme.text)
            Text(tagline)
                .font(.subheadline)
                .foregroundStyle(KayaTheme.subtleText)
            if let profile {
                let run = Momentum.currentRun(in: profile.activeDays)
                if run >= 2 {
                    Label("\(run) days in a row — nice pace.", systemImage: "flame.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(KayaTheme.accent)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Routines due today that aren't finished — feeds the briefing card.
    private var dueToday: [Routine] {
        routines.filter { $0.occurs(on: Date()) && !$0.isFinished }
    }

    /// A quiet "what's today" card above the footer — Kaya writes the line,
    /// tapping it opens the first routine due.
    private func briefingCard(_ text: String) -> some View {
        Button {
            if let first = dueToday.first { activeRoutine = first }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(KayaTheme.accent)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(KayaTheme.text)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(KayaTheme.subtleText)
            }
            .kayaCard(padding: 14)
            .padding(.horizontal, 32)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the first routine planned for today")
    }

    /// One-tap start for anything due today — instant, no AI needed.
    /// Complements the briefing card (which only opens the first one).
    @ViewBuilder
    private var todayChips: some View {
        if dueToday.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dueToday) { routine in
                        Button {
                            activeRoutine = routine
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: routine.iconSymbol)
                                    .font(.caption)
                                Text(routine.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if let minutes = routine.scheduledMinutes {
                                    Text(KayaSchedule.timeString(minutes))
                                        .font(.caption2)
                                        .foregroundStyle(KayaTheme.subtleText)
                                }
                            }
                            .foregroundStyle(KayaTheme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(KayaTheme.warm.opacity(0.55)))
                            .overlay(Capsule().stroke(KayaTheme.accent.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(KayaChipButtonStyle())
                        .accessibilityHint("Starts this routine")
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 10)
        }
    }

    /// A deterministic fact about how things went lately — the model can
    /// weave it into the briefing but never has to invent it.
    private var recentOutcome: String? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? .distantPast
        guard let last = routines
            .filter({ ($0.finishedAt ?? .distantPast) >= cutoff })
            .sorted(by: { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) })
            .first else { return nil }
        var parts: [String] = []
        if last.difficulty == .hard { parts.append("felt hard") }
        if last.lastRunHadSkips { parts.append("had skipped steps") }
        if let note = last.lastUserNote, !note.isEmpty { parts.append("they said: \(note)") }
        guard !parts.isEmpty else { return nil }
        return "Last time \u{201C}\(last.title)\u{201D} \(parts.joined(separator: "; "))."
    }

    private func loadBriefing() async {
        let due = dueToday
        guard !due.isEmpty else { briefing = nil; return }
        let titles = due.map(\.title)
        let times = due.map { $0.scheduledMinutes.map(KayaSchedule.timeString) ?? "any time" }
        if let text = try? await aiService.dayBriefing(
            routineTitles: titles, times: times,
            recentOutcome: recentOutcome, profile: profile
        ) {
            briefing = text
        } else {
            briefing = due.count == 1
                ? "Today: \(titles[0])\(due[0].scheduledMinutes.map { " at " + KayaSchedule.timeString($0) } ?? "")"
                : "Today you have \(due.count) routines planned."
        }
    }

    private var voiceCaption: String {
        if voice.permissionDenied || voice.isUnsupported {
            return "Voice isn't available on this device — open Routines to browse by tap."
        }
        if voice.isListening {
            return "Say a routine name, or a new goal like “buy bread”."
        }
        return "Say a routine name or a new goal.\nKaya takes it from there."
    }

    // MARK: - Conversation panel

    /// Closes the chat — used by the pull-down grabber, the "bye" voice
    /// command path, and any code that wants the conversation gone.
    private func closeConversation() {
        conversationEpoch += 1
        finishVoiceSession(route: false)
        speech.stop()
        showConversation = false
        conversation = []
        pendingDraft = nil
        pendingGoal = ""
        pendingQuestion = .none
        pendingFact = nil
        micRequestedAfterSpeech = false
    }

    /// Pull-to-dismiss — dragging the grabber (or the gap above the
    /// bubbles) down past ~90pt closes the chat; a fast flick closes too.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                chatDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let dismiss = value.translation.height > 90
                    || value.predictedEndTranslation.height > 180
                if dismiss { closeConversation() }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    chatDragOffset = 0
                }
            }
    }

    /// Bottom chat panel — Kaya's replies on the left, what you said on the
    /// right, plus tappable suggestions in case speaking is hard right now.
    /// No close button: pull the grabber down, or just say "bye".
    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Drag handle — the pull-down-to-close affordance.
            Capsule()
                .fill(KayaTheme.subtleText.opacity(0.4))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .gesture(closeDrag)
                .accessibilityHidden(true)

            // Cap the visible history so a long chat can't overflow the
            // panel — the list scrolls and keeps the latest in view.
            chatMessages

            // Quick replies — a scrollable row, like message suggestions.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if pendingFact != nil {
                        // A remember-offer takes over the chip row — the
                        // only two answers that make sense right now.
                        chipButton("Remember this") { _ = handleFactReply("yes") }
                        chipButton("No thanks") { _ = handleFactReply("no") }
                    } else {
                        ForEach(backupSuggestions, id: \.self) { suggestion in
                            chipButton(suggestion) {
                                autoRouteTask?.cancel()
                                voice.stopListening()
                                userSaid(suggestion)
                                routeAndRespond(suggestion)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .offset(y: chatDragOffset)
        // VoiceOver dismissal — the scrub gesture closes the chat now that
        // there's no visible close button.
        .accessibilityAction(.escape) { closeConversation() }
    }

    /// One quick-reply capsule in the chip row.
    private func chipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(.thinMaterial))
            .foregroundStyle(KayaTheme.accent)
            .overlay(Capsule().stroke(KayaTheme.accent.opacity(0.35), lineWidth: 1))
            .buttonStyle(KayaChipButtonStyle())
    }

    /// Bubbles slide in from their own side — Kaya's from the left, yours
    /// from the right — with a small settle, like a real messenger.
    private func chatTransition(isKaya: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: isKaya ? .leading : .trailing)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.96))
    }

    private var chatMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let entries = Array(conversation.suffix(8))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        // A run is a block of same-author bubbles — the tail
                        // and avatar only show on the last one of the run.
                        let lastOfRun = index == entries.count - 1
                            || entries[index + 1].isKaya != entry.isKaya
                        let firstOfRun = index == 0
                            || entries[index - 1].isKaya != entry.isKaya
                        chatBubble(entry, tail: lastOfRun, avatar: lastOfRun)
                            .id(entry.id)
                            .padding(.top, firstOfRun ? 10 : 4)
                            .transition(chatTransition(isKaya: entry.isKaya))
                    }
                    // Typing dots sit in the message flow itself while the
                    // on-device model is composing a reply.
                    if isGenerating {
                        typingBubble
                            .id("typing")
                            .padding(.top, 10)
                            .transition(chatTransition(isKaya: true))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25),
                           value: conversation.count)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25),
                           value: isGenerating)
            }
            // About two bubbles tall — older messages scroll underneath,
            // so the chat stays a glanceable strip rather than a full page.
            .frame(height: 150)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: conversation.count) { _, _ in
                if let last = conversation.last {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: isGenerating) { _, generating in
                if generating {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("typing", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Kaya's bubbles hug the left in warm card tones; yours hug the right
    /// in a glowing accent gradient. Only the last bubble of a same-author
    /// run gets the tail and avatar — the run reads as one thought.
    private func chatBubble(_ entry: ChatEntry, tail: Bool, avatar: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if entry.isKaya {
                kayaAvatar.opacity(avatar ? 1 : 0)
            } else {
                Spacer(minLength: 48)
            }
            Text(entry.text)
                .font(.subheadline)
                .lineSpacing(3)
                .foregroundStyle(entry.isKaya ? KayaTheme.text : KayaTheme.onAccent)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(bubbleBackground(isKaya: entry.isKaya, tail: tail))
                // No container card — each bubble carries its own soft
                // shadow so it floats on the background.
                .shadow(color: .black.opacity(entry.isKaya ? 0.4 : 0.3),
                        radius: 10, y: 4)
            if entry.isKaya { Spacer(minLength: 48) }
        }
    }

    /// The app icon doubles as Kaya's chat avatar — same face everywhere.
    private var kayaAvatar: some View {
        Image("LaunchIcon")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            .overlay(Circle().stroke(KayaTheme.accent.opacity(0.35), lineWidth: 1))
    }

    private func bubbleBackground(isKaya: Bool, tail: Bool) -> some View {
        let shape = isKaya
            ? UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: tail ? 4 : 18,
                bottomTrailingRadius: 18, topTrailingRadius: 18,
                style: .continuous)
            : UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 18,
                bottomTrailingRadius: tail ? 4 : 18, topTrailingRadius: 18,
                style: .continuous)
        return shape
            .fill(
                LinearGradient(
                    colors: isKaya
                        ? [KayaTheme.warm, KayaTheme.warm.opacity(0.82)]
                        : [KayaTheme.accent, KayaTheme.accent.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                shape.stroke(
                    isKaya ? KayaTheme.accent.opacity(0.14) : .white.opacity(0.12),
                    lineWidth: 1)
            )
    }

    /// Three pulsing dots — the familiar "Kaya is typing" cue.
    private var typingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            kayaAvatar
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(KayaTheme.subtleText)
                        .frame(width: 7, height: 7)
                        .phaseAnimator([false, true]) { view, phase in
                            view.opacity(phase ? 1.0 : 0.3)
                                .scaleEffect(phase ? 1.0 : 0.75)
                        } animation: { _ in
                            .easeInOut(duration: 0.5).delay(Double(dot) * 0.15)
                        }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 4,
                    bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous)
                .fill(KayaTheme.warm)
            )
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            Spacer(minLength: 48)
        }
        .accessibilityLabel("Kaya is thinking")
    }

    /// Contextual quick replies — follow-up options once a draft exists,
    /// otherwise things the user might plausibly want: their common goals,
    /// progress questions, then a couple of gentle defaults.
    private var backupSuggestions: [String] {
        if isGenerating { return [] }
        if pendingDraft != nil {
            switch pendingQuestion {
            case .repeatRule:
                return ["Just once", "Every day", "Every week", "Mondays", "Start it now"]
            case .scheduleTime:
                return ["8 AM", "In the morning", "Any time", "Start it now"]
            case .none:
                return ["Start it", "Show the steps", "Try again", "Edit it", "Never mind"]
            case .rememberFact:
                return [] // the fact chips take over the row
            }
        }
        var items: [String] = []
        if let goals = profile?.commonGoalsText {
            items += goals.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if !routines.isEmpty { items += ["How am I doing?", "What's left today?"] }
        items += ["Get ready in the morning", "Make a snack"]
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }.prefix(7).map { $0 }
    }

    // MARK: - Voice session

    private func appendKaya(_ text: String, speak: Bool = true) {
        conversation.append(ChatEntry(isKaya: true, text: text))
        if speak { speakReply(text) }
    }

    /// Reads a reply aloud when "Kaya speaks replies" is on. The mic pauses
    /// while she talks — so she can't hear herself — and resumes when she's
    /// done, via `keepListening` in the finish callback. Multi-line messages
    /// (step lists) read only the first line; the rest stays on screen.
    private func speakReply(_ text: String) {
        guard speakReplies, showConversation else { return }
        let spoken = text.components(separatedBy: "\n").first ?? text
        if voice.isListening { voice.stopListening() }
        // Queued — consecutive bubbles speak in order instead of cutting
        // each other off.
        speech.speak(spoken, queue: true) { [self] in
            keepListening()
        }
    }

    /// Records (or updates) the user's latest spoken line as a chat bubble.
    private func userSaid(_ text: String) {
        if conversation.last?.isKaya == false {
            conversation[conversation.count - 1].text = text
        } else {
            conversation.append(ChatEntry(isKaya: false, text: text))
        }
    }

    private func toggleVoice() {
        if voice.isListening {
            finishVoiceSession(route: true)
            return
        }
        // Tapping while Kaya is mid-reply cuts her off — the mic wins.
        speech.stop()
        // Mid-conversation tap: resume listening without wiping the chat.
        // Must still go through enable() — a bare startListening() no-ops
        // silently when permission was never granted (dead orb tap).
        if showConversation {
            Task {
                guard await voice.enable() else {
                    appendKaya("I can't hear you right now — check the microphone in Settings, or tap a suggestion below.")
                    return
                }
                voice.startListening()
            }
            return
        }
        heardText = ""
        conversation = []
        showConversation = true
        appendKaya("Tell me a goal or a routine name — I'll take it from there.")
        Task {
            guard await voice.enable() else {
                appendKaya("I can't hear you right now — check the microphone in Settings, or tap a suggestion below.")
                return
            }
            // [weak voice] — the closure is stored on `voice` itself;
            // a strong capture would retain the service forever.
            voice.onTranscript = { [weak voice] in
                guard let voice else { return }
                heardText = voice.transcript
                let t = heardText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { userSaid(t) }
                scheduleAutoRoute()
            }
            // If the opener is still being read aloud, let it finish — the
            // speak callback's keepListening honors the pending request.
            if !speech.isSpeaking {
                voice.startListening()
            } else {
                micRequestedAfterSpeech = true
            }
        }
    }

    /// Stop and act once the transcript has been quiet for a moment —
    /// the "it just does it" part of the experience.
    private func scheduleAutoRoute() {
        autoRouteTask?.cancel()
        let snapshot = voice.transcript
        autoRouteTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, voice.transcript == snapshot, !snapshot.isEmpty else { return }
            finishVoiceSession(route: true)
        }
    }

    private func finishVoiceSession(route: Bool) {
        autoRouteTask?.cancel()
        let text = voice.transcript
        voice.stopListening()
        heardText = ""
        if route { routeAndRespond(text) }
    }

    /// Kaya replies in the panel first, then acts — the short delay lets the
    /// user read the response before the screen changes. When she speaks
    /// replies aloud, the action waits until she's finished the line.
    /// Listening stops for real once we leave this screen.
    private func respondThen(_ message: String, _ action: @escaping () -> Void) {
        appendKaya(message, speak: false)
        // If the chat closes (grab, "bye", a new session) before the delay
        // ends, the action must not fire — closing means "don't do that".
        let epoch = conversationEpoch
        let finish = {
            guard epoch == conversationEpoch, showConversation else { return }
            closeConversation()
            action()
        }
        guard speakReplies else {
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                finish()
            }
            return
        }
        voice.stopListening()
        speech.speak(message)
        Task {
            // Give the synthesizer a moment to start, then wait it out.
            try? await Task.sleep(for: .milliseconds(300))
            while speech.isSpeaking {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .milliseconds(350))
            finish()
        }
    }

    /// The mic only comes back on by itself when Kaya is waiting on an
    /// answer — the scheduling questions during routine creation. Everywhere
    /// else it stays off until tapped: the mic is never hot when it isn't
    /// being used. A short delay keeps recognition from catching the tail
    /// of Kaya's own voice.
    private func keepListening() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard showConversation, !isGenerating,
                  voice.isAuthorized, !voice.isUnsupported,
                  !voice.isListening, !speech.isSpeaking,
                  pendingQuestion != .none || micRequestedAfterSpeech else { return }
            micRequestedAfterSpeech = false
            voice.startListening()
        }
    }

    /// Entry point for anything the user says or taps.
    ///
    /// Two paths, chosen by reliability: while Kaya is asking schedule
    /// questions, the local parsers are used — the small on-device model is
    /// inaccurate at extracting weekdays/times, but the keyword parsers are
    /// exact. At open stages the model interprets the sentence directly,
    /// which handles phrasing keywords can't. Keyword parsing stays the
    /// fallback either way.
    /// Words the recognizer emits for breath, static, or hesitation —
    /// not a message, so Kaya stays quiet instead of replying to nothing.
    private static let noiseWords: Set<String> = [
        "um", "uh", "hmm", "hm", "mm", "mmm", "ah", "eh", "oh", "ooh",
        "the", "a", "an", "i"
    ]

    /// True when the transcript is only filler — every word is noise.
    private func isNoise(_ t: String) -> Bool {
        let words = t.split(separator: " ")
        return !words.isEmpty
            && words.allSatisfy { Self.noiseWords.contains(String($0)) }
    }

    /// The live partial transcript can leave a stray user bubble of pure
    /// punctuation behind — sweep it so silence leaves no trace.
    private func dropStrayBlankBubble() {
        if let last = conversation.last, !last.isKaya,
           last.text.lowercased()
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .trimmingCharacters(in: .punctuationCharacters).isEmpty {
            conversation.removeLast()
        }
        heardText = ""
    }

    private func routeAndRespond(_ raw: String) {
        let t = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        // Silence or recognizer noise isn't a message — don't reply to it.
        // If a question is open the mic simply comes back and waits again.
        guard !t.isEmpty, !isNoise(t) else {
            dropStrayBlankBubble()
            keepListening()
            return
        }
        if handleGlobalCommand(t) { return }
        if handleFactReply(t) { return }
        // A remember-offer is a soft question — if the reply wasn't yes/no,
        // let it go instead of blocking the model for the rest of the chat.
        if pendingQuestion == .rememberFact {
            if let fact = pendingFact { declinedFacts.insert(fact.lowercased()) }
            pendingFact = nil
            pendingQuestion = .none
        }
        let forceKeywords = forceKeywordOnce
        forceKeywordOnce = false
        let canUseModel = aiService.availability == .available && !forceKeywords
        // While a scheduling question is open, the exact parsers get first
        // dibs — the small model isn't reliable at extracting weekdays and
        // times. A message that doesn't parse is probably a side question or
        // chat — the model can take it; the question simply stays open.
        if pendingQuestion == .repeatRule || pendingQuestion == .scheduleTime {
            if applyScheduleAnswer(t) { return }
            guard canUseModel else { reaskScheduleQuestion(); return }
        } else {
            guard canUseModel else {
                routeWithKeywords(raw)
                return
            }
        }
        isGenerating = true
        let stage = currentStage
        let titles = routines.map(\.title)
        let userProfile = profile
        let recent = conversation.suffix(6).map {
            $0.isKaya ? "Kaya: \($0.text)" : "User: \($0.text)"
        }
        Task {
            if let intent = try? await aiService.interpretConversation(
                transcript: raw, stage: stage,
                routineTitles: titles, history: recent, profile: userProfile
            ) {
                isGenerating = false
                act(on: intent, fallbackText: raw)
            } else {
                isGenerating = false
                routeWithKeywords(raw)
            }
        }
    }

    /// Plain-language description of where the conversation is — lets the
    /// model resolve short replies like "yes" or "8 am".
    private var currentStage: String {
        if pendingQuestion == .rememberFact {
            return "Kaya asked if she should remember a fact the user shared"
        }
        if pendingDraft != nil {
            switch pendingQuestion {
            case .repeatRule:
                return "Kaya asked if the routine should repeat"
            case .scheduleTime:
                return "Kaya asked what time of day"
            case .none:
                return "A draft routine is ready — waiting for start/show/edit/schedule answers"
            case .rememberFact:
                return "" // unreachable — handled above
            }
        }
        return "Waiting for the user's request"
    }

    /// Act on the model's interpretation. The model's reply text is used
    /// for Kaya's bubble; its entity fields are ignored (local parsing is
    /// more accurate for weekdays and times).
    private func act(on intent: ConversationIntent, fallbackText raw: String) {
        switch intent.intent.lowercased() {
        case "newgoal":
            let goal = intent.subject.isEmpty ? raw : intent.subject
            pendingDraft = nil
            pendingQuestion = .none
            generateInConversation(goal)
        case "openroutine":
            if let routine = routines.first(where: { titleMatches($0.title, in: intent.subject.lowercased()) })
                ?? routines.first(where: { titleMatches($0.title, in: raw.lowercased()) }) {
                respondThen(intent.reply.isEmpty ? "Opening \u{201C}\(routine.title)\u{201D}." : intent.reply) {
                    activeRoutine = routine
                }
            } else {
                generateInConversation(intent.subject.isEmpty ? raw : intent.subject)
            }
        case "start":
            if let draft = pendingDraft {
                let routine = RoutineStore.save(draft, in: modelContext)
                offerReminderIfNew(routine)
                respondThen(intent.reply.isEmpty ? "Starting \u{201C}\(routine.title)\u{201D}. Take your time." : intent.reply) {
                    pendingDraft = nil
                    pendingQuestion = .none
                    activeRoutine = routine
                }
            } else if let routine = routines.first {
                respondThen(intent.reply.isEmpty ? "Opening \u{201C}\(routine.title)\u{201D}." : intent.reply) {
                    activeRoutine = routine
                }
            } else {
                appendKaya(intent.reply.isEmpty ? "Tell me a goal first — I'll make the routine." : intent.reply)
                keepListening()
            }
        case "showsteps":
            if let draft = pendingDraft {
                let list = draft.steps.enumerated()
                    .map { "\($0.offset + 1). \($0.element.title)" }
                    .joined(separator: "\n")
                appendKaya("Here are the steps:\n\(list)")
            } else {
                appendKaya(intent.reply.isEmpty ? "There's no routine yet — tell me a goal." : intent.reply)
            }
            keepListening()
        case "retry":
            if let draft = pendingDraft {
                pendingDraft = nil
                pendingQuestion = .none
                let goal = pendingGoal.isEmpty
                    ? (draft.goal.isEmpty ? draft.title : draft.goal)
                    : pendingGoal
                generateInConversation(goal)
            } else {
                appendKaya(intent.reply.isEmpty ? "Tell me a goal and I'll write the steps." : intent.reply)
                keepListening()
            }
        case "edit":
            if let draft = pendingDraft {
                let bare = raw.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters)
                if ["edit", "edit it", "change", "change it"].contains(bare) {
                    // No actual edit instruction — open the editor instead.
                    respondThen("Opening the editor — change anything you like.") {
                        self.pendingDraft = nil
                        self.pendingQuestion = .none
                        voiceRoute = .review(draft)
                    }
                } else {
                    editDraftInConversation(draft: draft, instruction: raw, opening: intent.reply)
                }
            } else {
                appendKaya(intent.reply.isEmpty ? "Nothing to edit yet — tell me a goal first." : intent.reply)
                keepListening()
            }
        case "cancel":
            pendingDraft = nil
            pendingGoal = ""
            pendingQuestion = .none
            appendKaya(intent.reply.isEmpty ? "Okay — nothing saved." : intent.reply)
            keepListening()
        case "restart":
            pendingDraft = nil
            pendingGoal = ""
            pendingQuestion = .none
            appendKaya(intent.reply.isEmpty
                       ? "Okay, fresh start. What should we make a routine for?"
                       : intent.reply)
            keepListening()
        case "chat":
            // Small talk — the model's reply is the actual conversation.
            appendKaya(intent.reply.isEmpty
                       ? "I'm here — tell me what's on your mind, or say a goal."
                       : intent.reply)
            keepListening()
        case "progress":
            // Numbers come from real data — the model's reply is only a
            // fallback, since the small model isn't reliable with figures.
            appendKaya(progressReply(for: raw)
                       ?? (intent.reply.isEmpty
                           ? "I don't have your numbers yet — finish a routine and I'll keep track."
                           : intent.reply))
            keepListening()
        case "suggest":
            // "What should I do now?" — real candidates from SwiftData;
            // the model only picks and phrases, it never invents routines.
            suggestNextRoutine()
        case "answer":
            // The model thinks it's a reply to a question — let the exact
            // local parsers take it, once, rather than trusting reply text.
            forceKeywordOnce = true
            routeAndRespond(raw)
        default:
            if !intent.reply.isEmpty {
                appendKaya(intent.reply)
            } else {
                appendKaya("I didn't quite get that — try again, or tap a suggestion.")
            }
            keepListening()
        }
        // After the reply lands, surface any durable fact the user shared —
        // offered once, only when nothing else is waiting on an answer.
        offerToRemember(intent)
    }

    /// The model heard a durable fact about the user ("I work night
    /// shifts"). Kaya asks before saving — she never remembers silently,
    /// and the offer only appears when the conversation isn't mid-question.
    private func offerToRemember(_ intent: ConversationIntent) {
        let fact = intent.learnedFact
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !fact.isEmpty, pendingFact == nil, pendingQuestion == .none,
              let profile else { return }
        let key = fact.lowercased()
        guard !profile.learnedFacts.contains(where: { $0.lowercased() == key }),
              !declinedFacts.contains(key) else { return }
        pendingFact = fact
        pendingQuestion = .rememberFact
        appendKaya("Want me to remember that — \u{201C}\(fact)\u{201D}? You can remove it anytime in You.")
    }

    /// Yes/no answers while a remember-offer is pending. Returns true when
    /// the utterance was consumed — anything else falls through to normal
    /// routing and the offer stays visible as chips.
    /// A digit in the reply means it isn't a clean yes/no ("ok 8 am" is
    /// answering something else) — let it fall through rather than
    /// swallowing the rest of what they said.
    private func handleFactReply(_ t: String) -> Bool {
        guard pendingFact != nil, !t.contains(where: \.isNumber) else { return false }
        let yes = ["yes", "yeah", "yep", "sure", "remember", "okay", "ok",
                   "oo", "opo", "sige", "tandaan", "pwede"]
        let no = ["no", "nope", "nah", "don't", "no thanks", "not now",
                  "hindi", "huwag", "ayaw", "wag"]
        if yes.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) {
            guard let fact = pendingFact, let profile else { return true }
            pendingFact = nil
            pendingQuestion = .none
            profile.learnedFacts.append(fact)
            // Invalidate first — if the redistill fails, the fallback
            // context (raw facts) stays correct instead of going stale.
            profile.aiContextSummary = ""
            try? modelContext.save()
            appendKaya("I'll remember that.")
            keepListening()
            // Refresh the distilled context so the fact reaches every prompt.
            Task {
                if let summary = try? await LocalAIService().distillProfile(profile: profile) {
                    profile.aiContextSummary = summary
                    try? modelContext.save()
                }
            }
            return true
        }
        if no.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) {
            if let fact = pendingFact { declinedFacts.insert(fact.lowercased()) }
            pendingFact = nil
            pendingQuestion = .none
            appendKaya("Okay — I won't keep that.")
            keepListening()
            return true
        }
        return false
    }

    /// "What should I do now?" — candidates are deterministic (unfinished,
    /// due-today, already-started), the model picks one and phrases why.
    private func suggestNextRoutine() {
        let pool = routines.filter { !$0.isFinished }.prefix(5)
        guard !pool.isEmpty else {
            appendKaya("Nothing planned right now — tell me a goal and I'll make a routine for it.")
            keepListening()
            return
        }
        let candidates = pool.map { routine -> String in
            var s = routine.title
            if let minutes = routine.scheduledMinutes {
                s += " at \(KayaSchedule.timeString(minutes))"
            }
            if routine.hasStarted { s += " (already started)" }
            return s
        }
        isGenerating = true
        Task {
            let reply = try? await aiService.suggestNext(candidates: candidates, profile: profile)
            isGenerating = false
            appendKaya(reply ?? "How about \u{201C}\(pool[0].title)\u{201D}? Say \u{201C}start it\u{201D} when you're ready.")
            keepListening()
        }
    }

    /// Keyword-side detection for the suggest intent — runs before goal
    /// parsing so "what should I do" never becomes a routine title.
    private func isSuggestRequest(_ t: String) -> Bool {
        let phrases = ["what should i do", "what can i do", "what do i do",
                       "suggest something", "suggest a routine", "what's next",
                       "anything to do", "recommend", "ano gagawin", "ano ang gagawin",
                       "anu gagawin", "ano pwede", "may suggestion"]
        return phrases.contains(where: { t.contains($0) })
    }

    /// "Make step 3 shorter" — natural-language editing on the pending
    /// draft. Falls back to opening the editor if the model can't do it.
    private func editDraftInConversation(draft: RoutineDraft, instruction: String, opening: String) {
        isGenerating = true
        if !opening.isEmpty { appendKaya(opening) }
        Task {
            if let edited = try? await aiService.editDraft(
                draft: draft, instruction: instruction, profile: profile
            ) {
                isGenerating = false
                pendingDraft = edited
                appendKaya("Updated — \u{201C}\(edited.title)\u{201D} now has \(edited.steps.count) steps. Say \u{201C}show the steps\u{201D} or \u{201C}start it\u{201D}.")
                keepListening()
            } else {
                isGenerating = false
                respondThen("Opening the editor — change anything you like.") {
                    self.pendingDraft = nil
                    self.pendingQuestion = .none
                    voiceRoute = .review(draft)
                }
            }
        }
    }

    /// Keyword router — the fallback path when the on-device model is
    /// unavailable. If a draft is already on the table, the reply is treated
    /// as a follow-up ("start it", "try again"…). Otherwise speech routes to
    /// a saved routine, a template, or a fresh goal — all without leaving
    /// this screen until the routine starts.
    private func routeWithKeywords(_ raw: String) {
        let t = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !t.isEmpty else {
            appendKaya("I didn't catch anything — tap a suggestion or press to talk again.")
            keepListening()
            return
        }

        if handleGlobalCommand(t) { return }

        if let reply = smallTalkReply(for: t) {
            appendKaya(reply)
            keepListening()
            return
        }

        if let reply = progressReply(for: t) {
            appendKaya(reply)
            keepListening()
            return
        }

        if isSuggestRequest(t) {
            suggestNextRoutine()
            return
        }

        if pendingDraft != nil {
            handleDraftReply(t)
            return
        }

        if let routine = routines.first(where: { titleMatches($0.title, in: t) }) {
            respondThen("Opening \u{201C}\(routine.title)\u{201D}.") {
                activeRoutine = routine
            }
            return
        }
        if let template = RoutineStore.templates.first(where: { titleMatches($0.title, in: t) }) {
            presentDraft(template)
            return
        }

        var goal = t
        let prefixes = [
            "create a routine to ", "create a routine for ", "create ",
            "make a routine to ", "make a routine for ", "make ",
            "new routine to ", "new ", "start a routine to ",
            "i want to ", "help me ", "kaya "
        ]
        for prefix in prefixes where goal.hasPrefix(prefix) {
            goal = String(goal.dropFirst(prefix.count))
            break
        }
        guard !goal.isEmpty else {
            appendKaya("I didn't get a goal from that — try again, or tap a suggestion.")
            keepListening()
            return
        }
        generateInConversation(goal)
    }

    /// Always-on commands — closing the chat and moving between tabs work
    /// mid-draft too, so nothing in the app ever requires a tap once the
    /// conversation is open. Runs before the model is asked, on both the
    /// AI and keyword paths, so a stray intent can't swallow "bye".
    private func handleGlobalCommand(_ t: String) -> Bool {
        switch t {
        case "close", "close the chat", "bye", "goodbye", "that's all", "thats all",
             "i'm done", "im done", "enough", "stop listening", "that's it", "thats it",
             "tapos na", "tapos na ako", "salamat", "paalam", "ayos na", "okay na ako",
             "sige bye":
            respondThen("Okay — I'm right here when you need me.") { }
        case "show my routines", "my routines", "open routines", "show routines",
             "the calendar", "my calendar", "show calendar", "open the calendar",
             "mga routine", "routines ko", "mga routines ko", "iskedyul", "calendar",
             "mga iskedyul":
            respondThen("Opening your routines and calendar.") { selectedTab = 1 }
        case "show my progress", "my progress", "open progress",
             "progress", "progress ko", "unlad ko":
            respondThen("Here's your progress.") { selectedTab = 2 }
        case "about me", "my profile", "my answers", "open you", "my settings",
             "change my answers", "profile ko", "tungkol sa akin", "sarili ko",
             "mga sagot ko":
            respondThen("Here are your saved answers.") { selectedTab = 3 }
        case "home", "go home", "back to kaya", "back home", "umuwi", "sa bahay",
             "balik sa kaya":
            respondThen("Back to Kaya.") { selectedTab = 0 }
        default:
            return false
        }
        return true
    }

    /// Small talk on the keyword path — greetings, feelings, and questions
    /// about Kaya get a warm canned reply instead of being mistaken for a
    /// routine goal (which is what "hi" would otherwise generate). Exact
    /// matches guard short words; feelings and questions match by phrase.
    private func smallTalkReply(for t: String) -> String? {
        let name = profile?.name ?? ""
        let hi = name.isEmpty ? "Hi!" : "Hi, \(name)!"
        let exact: [String: String] = [
            "hi": "\(hi) I'm here — tell me a goal, or just talk to me.",
            "hello": "\(hi) I'm here — tell me a goal, or just talk to me.",
            "hey": "\(hi) What's on your mind?",
            "hey kaya": "\(hi) What's on your mind?",
            "hi kaya": "\(hi) I'm here — tell me a goal, or just talk to me.",
            "hello kaya": "\(hi) I'm here — tell me a goal, or just talk to me.",
            "yo": "Hey — what can I do for you?",
            "hoy": "Hey! Ano ang kaya kong tulungan sa'yo? Or just tell me a goal.",
            "good morning": "Good morning\(name.isEmpty ? "" : ", \(name)")! A calm start — anything you'd like to do today?",
            "good afternoon": "Good afternoon! Anything on your mind?",
            "good evening": "Good evening! Want to wind down or get something done?",
            "magandang umaga": "Magandang umaga! Anything you'd like to do today?",
            "magandang hapon": "Magandang hapon! Anything on your mind?",
            "magandang gabi": "Magandang gabi! Winding down or getting something done?",
            "kamusta": "I'm here and listening. What's on your mind?",
            "kumusta": "I'm here and listening. What's on your mind?",
            "musta": "I'm here and listening. What's on your mind?",
            "thanks": "Anytime — I'm glad I could help.",
            "thank you": "Anytime — I'm glad I could help.",
            "thank you kaya": "Anytime — I'm glad I could help.",
            "thanks kaya": "Anytime — I'm glad I could help.",
            "ty": "Anytime.",
            "sorry": "No need to be sorry — take your time.",
            "my bad": "All good — no rush here.",
            "lol": "Glad you're having fun.",
            "haha": "Glad you're having fun.",
            "hehe": "Glad you're having fun.",
            "nice": "Thanks — I'm just here to help.",
            "cool": "Glad you think so.",
            "nope": "No worries — I'm here when something comes to mind.",
            "nothing": "That's okay — I'm here whenever you have a goal in mind.",
            "nothing much": "Fair enough — I'm here when something comes to mind.",
            "good night": "Sleep well — I'll be here tomorrow.",
            "goodnight": "Sleep well — I'll be here tomorrow.",
            "help": "I can turn a goal into small steps, keep time while you do them, and cheer you on at the end. Try saying a goal — like \u{201C}make my bed\u{201D}.",
            "kaya": "Yes? I'm listening.",
            "ok lang": "Alright — I'm here when you're ready.",
        ]
        if let reply = exact[t] { return reply }

        // Phrase matches — feelings and questions can arrive in longer
        // sentences, so these match anywhere in the transcript.
        let phrases: [(String, String)] = [
            ("how are you", "I'm doing well — thanks for asking. How are you feeling today?"),
            ("how's it going", "I'm doing well — thanks for asking. How are you feeling today?"),
            ("hows it going", "I'm doing well — thanks for asking. How are you feeling today?"),
            ("how have you been", "I've been right here, ready when you are. How about you?"),
            ("kamusta ka", "I'm here and listening — ikaw, kamusta ka?"),
            ("kumusta ka", "I'm here and listening — ikaw, kamusta ka?"),
            ("what's up", "Not much — just here for you. What would you like to do?"),
            ("whats up", "Not much — just here for you. What would you like to do?"),
            ("wassup", "Not much — just here for you. What would you like to do?"),
            ("i'm tired", "That's okay — we can keep it small today. Want an easy routine, or just to sit for a bit?"),
            ("im tired", "That's okay — we can keep it small today. Want an easy routine, or just to sit for a bit?"),
            ("i feel tired", "That's okay — we can keep it small today. Want an easy routine, or just to sit for a bit?"),
            ("pagod ako", "That's okay — we can keep it small today. Pahinga muna, or a gentle routine?"),
            ("pagod na ako", "That's okay — we can keep it small today. Pahinga muna, or a gentle routine?"),
            ("i'm sad", "I'm sorry it's heavy right now. One small step at a time — I'm with you."),
            ("im sad", "I'm sorry it's heavy right now. One small step at a time — I'm with you."),
            ("i feel sad", "I'm sorry it's heavy right now. One small step at a time — I'm with you."),
            ("feeling down", "I'm sorry it's heavy right now. One small step at a time — I'm with you."),
            ("malungkot ako", "I'm sorry it's heavy right now. Isang maliit na hakbang lang — I'm with you."),
            ("i'm upset", "I'm sorry it's heavy right now. One small step at a time — I'm with you."),
            ("i'm anxious", "That's okay — breathe first. When you're ready, we can take just one small step."),
            ("im anxious", "That's okay — breathe first. When you're ready, we can take just one small step."),
            ("i'm stressed", "That's okay — breathe first. When you're ready, we can take just one small step."),
            ("im stressed", "That's okay — breathe first. When you're ready, we can take just one small step."),
            ("stressed out", "That's okay — breathe first. When you're ready, we can take just one small step."),
            ("i'm happy", "Love that for you — let's keep the good momentum going."),
            ("im happy", "Love that for you — let's keep the good momentum going."),
            ("i feel good", "Love that for you — let's keep the good momentum going."),
            ("i feel great", "Love that for you — let's keep the good momentum going."),
            ("masaya ako", "Love that — masaya rin ako para sa'yo. Want to channel it into a goal?"),
            ("i'm bored", "We could build a routine for something you've been meaning to do — want to try?"),
            ("im bored", "We could build a routine for something you've been meaning to do — want to try?"),
            ("bored ako", "We could build a routine for something you've been meaning to do — want to try?"),
            ("i'm scared", "That's okay — we can make it as small as you need. What's worrying you?"),
            ("im scared", "That's okay — we can make it as small as you need. What's worrying you?"),
            ("takot ako", "That's okay — we can make it as small as you need. What's worrying you?"),
            ("who are you", "I'm Kaya — I turn your goals into small steps you can do at your own pace, right here on this device."),
            ("what are you", "I'm Kaya — I turn your goals into small steps you can do at your own pace, right here on this device."),
            ("what's your name", "I'm Kaya. Nice to meet you."),
            ("whats your name", "I'm Kaya. Nice to meet you."),
            ("sino ka", "I'm Kaya — your companion for turning goals into small, doable steps."),
            ("ano ka", "I'm Kaya — your companion for turning goals into small, doable steps."),
            ("what can you do", "I can turn a goal into small steps, keep time while you do them, and cheer you on at the end. Try saying a goal — like \u{201C}make my bed\u{201D}."),
            ("what do you do", "I can turn a goal into small steps, keep time while you do them, and cheer you on at the end. Try saying a goal — like \u{201C}make my bed\u{201D}."),
            ("ano ang kaya mo", "I can turn a goal into small steps, keep time while you do them, and cheer you on. Sabihin mo lang ang goal mo."),
            ("i don't know", "No pressure — you could say a goal like \u{201C}tidy my desk\u{201D}, or just keep chatting."),
            ("i dont know", "No pressure — you could say a goal like \u{201C}tidy my desk\u{201D}, or just keep chatting."),
            ("not sure", "No pressure — you could say a goal like \u{201C}tidy my desk\u{201D}, or just keep chatting."),
            ("tell me a joke", "I'd offer a joke, but I'm better at routines. Want to turn something into small steps instead?"),
            ("the weather", "I live on your device, so I can't check the sky — but I can help you get ready to face it."),
            ("i love you", "That's very kind — I'm always here when you need a hand."),
            ("love you", "That's very kind — I'm always here when you need a hand."),
            ("you're great", "Thank you — I'm just here to help you do things your way."),
            ("youre great", "Thank you — I'm just here to help you do things your way."),
            ("you're smart", "Thank you — I'm just here to help you do things your way."),
            ("good job", "Thank you — I'm just here to help you do things your way."),
            ("ang galing mo", "Salamat — I'm just here to help you do things your way."),
            ("matutulog", "Sleep well — I'll be here tomorrow."),
            ("i miss you", "I'm right here — always just one tap or one sentence away."),
        ]
        for (phrase, reply) in phrases where t.contains(phrase) {
            return reply
        }
        return nil
    }

    // MARK: - Progress questions

    /// "How am I doing", "did I finish X", "what's left today" — answered
    /// from real SwiftData, never generated. Numbers are too important to
    /// trust to a small model.
    private func progressReply(for raw: String) -> String? {
        let t = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard isProgressQuestion(t) else { return nil }

        // A named routine in the question → report that routine's status.
        if let routine = routines.first(where: { titleMatches($0.title, in: t) }) {
            return routineStatusLine(routine)
        }
        if t.contains("skip") || t.contains("left out") || t.contains("naiwan")
            || t.contains("nilaktawan") || t.contains("inalis") {
            return skippedLine()
        }
        if t.contains("streak") || t.contains("in a row") || t.contains("sunud") {
            return streakLine()
        }
        if t.contains("today") || t.contains("left") || t.contains("planned")
            || t.contains("ngayong araw") || t.contains("ngayon") || t.contains("bukas") {
            return todayLine()
        }
        if t.contains("week") || t.contains("linggo") {
            return weekLine()
        }
        return totalsLine()
    }

    /// Only answer when it's actually a question — "start morning walk"
    /// contains a routine title but isn't asking for its status.
    private func isProgressQuestion(_ t: String) -> Bool {
        let signals = [
            "how am i", "how did i", "how have i", "how many", "how long",
            "how's my", "hows my", "how was", "did i", "have i", "what did i",
            "what have i", "what's left", "whats left", "what's planned",
            "what do i have", "when did i", "my stats", "my results",
            "my streak", "days in a row", "progress update", "how i'm doing",
            "how im doing",
            // Tagalog
            "natapos ko", "nakumpleto", "nagawa ko", "ano ang nagawa",
            "ilang", "kamusta na ako", "kamusta ako", "kelan ko", "ano ba ang"
        ]
        return signals.contains { t.contains($0) }
    }

    private func routineStatusLine(_ routine: Routine) -> String {
        let total = routine.sortedSteps.count
        let done = routine.completedCount
        let skipped = routine.steps.filter(\.skipped)
        let calendar = Calendar.current

        if routine.isFinished {
            var line = "\u{201C}\(routine.title)\u{201D} — finished"
            if let finished = routine.finishedAt {
                line += calendar.isDateInToday(finished) ? " today"
                    : calendar.isDateInYesterday(finished) ? " yesterday"
                    : " on \(finished.formatted(date: .abbreviated, time: .omitted))"
            }
            if let start = routine.startedAt, let end = routine.finishedAt {
                let mins = max(1, Int(end.timeIntervalSince(start) / 60))
                line += ", in about \(mins) min"
            }
            if let difficulty = routine.difficulty {
                line += ", and you said it felt \(difficulty.label.lowercased())"
            }
            if !skipped.isEmpty {
                line += ". You skipped \u{201C}\(skipped.map(\.title).joined(separator: ", "))\u{201D} — that's okay, you can do it again anytime"
            }
            return line + "."
        }
        if routine.hasStarted {
            var line = "\u{201C}\(routine.title)\u{201D} — \(done) of \(total) steps done"
            if !skipped.isEmpty {
                line += ", \(skipped.count) skipped"
            }
            line += ". You're on step \(min(routine.currentStepIndex + 1, total)) — it's saved, continue anytime."
            return line
        }
        var line = "\u{201C}\(routine.title)\u{201D} — not started yet"
        if routine.isScheduled {
            line += ", planned \(routine.scheduleLabel.lowercased())"
        }
        return line + "."
    }

    private func skippedLine() -> String {
        let skipped = routines.flatMap { routine in
            routine.steps.filter(\.skipped).map { "\u{201C}\($0.title)\u{201D} in \u{201C}\(routine.title)\u{201D}" }
        }
        if skipped.isEmpty {
            return "You haven't skipped anything — every step you've passed was one you finished."
        }
        let listed = skipped.prefix(3).joined(separator: ", ")
        let more = skipped.count > 3 ? " and \(skipped.count - 3) more" : ""
        return "Skipped steps: \(listed)\(more). Skipping is fine — they're still there whenever you want them."
    }

    private func streakLine() -> String {
        guard let profile else { return "I don't have your numbers yet — your progress starts with the first step." }
        let run = Momentum.currentRun(in: profile.activeDays)
        let best = Momentum.longestRun(in: profile.activeDays)
        if run >= 2 {
            return "You're on a \(run)-day run — showing up every day. Your best so far is \(best)."
        }
        if best >= 2 {
            return "Your longest run is \(best) days in a row. One step today starts a new one — no pressure."
        }
        return "No run yet — finishing even one step today starts the count."
    }

    private func todayLine() -> String {
        let due = dueToday
        let doneToday = routines.filter {
            $0.isFinished && $0.finishedAt.map { Calendar.current.isDateInToday($0) } == true
        }
        var parts: [String] = []
        if !doneToday.isEmpty {
            parts.append("Finished today: \(doneToday.map { "\u{201C}\($0.title)\u{201D}" }.joined(separator: ", "))")
        }
        if due.isEmpty {
            parts.append(doneToday.isEmpty
                         ? "Nothing planned for today — a good day to start something small"
                         : "Nothing else planned for today")
        } else {
            let remaining = due.map { routine in
                "\u{201C}\(routine.title)\u{201D}"
                    + (routine.scheduledMinutes.map { " at " + KayaSchedule.timeString($0) } ?? "")
            }.joined(separator: ", ")
            parts.append("Still to go: \(remaining)")
        }
        return parts.joined(separator: ". ") + "."
    }

    private func weekLine() -> String {
        guard let profile else { return "I don't have your numbers yet — your progress starts with the first step." }
        let count = profile.routinesFinishedThisWeek
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let titles = routines.filter { $0.isFinished && ($0.finishedAt ?? .distantPast) >= weekAgo }
            .map(\.title)
        if count == 0 {
            return "A quiet week so far — that's okay. Your routines are ready whenever you are."
        }
        var line = "This week: \(count) routine\(count == 1 ? "" : "s") finished"
        if !titles.isEmpty {
            line += " — \(titles.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))"
        }
        let run = Momentum.currentRun(in: profile.activeDays)
        if run >= 2 {
            line += ", and a \(run)-day run going"
        }
        return line + "."
    }

    private func totalsLine() -> String {
        guard let profile, profile.routinesFinished > 0 || profile.stepsFinished > 0 else {
            return "You haven't finished a routine yet — your progress starts with the very first step."
        }
        var line = "So far: \(profile.routinesFinished) routine\(profile.routinesFinished == 1 ? "" : "s") finished, \(profile.stepsFinished) steps done"
        let days = Momentum.activeDayCount(profile.activeDays)
        if days > 0 {
            line += ", across \(days) day\(days == 1 ? "" : "s")"
        }
        let run = Momentum.currentRun(in: profile.activeDays)
        if run >= 2 {
            line += " — and \(run) days in a row right now"
        }
        return line + "."
    }

    /// First time a routine is saved with a clock time, ask iOS for
    /// notification permission — the system dialog is the opt-in, and
    /// denying it changes nothing else. Never re-asks.
    private func offerReminderIfNew(_ routine: Routine) {
        guard routine.isScheduled, routine.scheduledMinutes != nil,
              ReminderService.shared.authorization == .notDetermined else { return }
        Task { await ReminderService.shared.requestPermission() }
    }

    /// Generating a routine inside the conversation — no screen change.
    private func generateInConversation(_ goal: String) {
        pendingGoal = goal
        isGenerating = true
        appendKaya("Making a routine for \u{201C}\(goal)\u{201D}… on this device.")
        Task {
            do {
                let draft = try await aiService.generateRoutine(
                    goal: goal,
                    useSimpleInstructions: profile?.prefersShortSteps ?? true,
                    languageCode: "en",
                    profile: profile
                )
                isGenerating = false
                presentDraft(draft)
            } catch {
                isGenerating = false
                appendKaya("I couldn't write a routine on this device right now. You can say another goal, or tap \u{201C}Edit it\u{201D} to build one yourself.")
                keepListening()
            }
        }
    }

    /// Kaya summarizes a ready draft, then asks whether it should repeat —
    /// the first scheduling question of the conversation.
    private func presentDraft(_ draft: RoutineDraft) {
        pendingDraft = draft
        pendingQuestion = .repeatRule
        appendKaya("Done — \u{201C}\(draft.title)\u{201D} has \(draft.steps.count) steps.")
        appendKaya("Should it repeat? Say \u{201C}just once\u{201D}, \u{201C}every day\u{201D}, \u{201C}every week\u{201D}, or a day like \u{201C}Mondays\u{201D}.")
        keepListening()
    }

    /// Handles replies while a draft is waiting: start, review steps,
    /// regenerate, hand off to the editor, schedule answers, or cancel.
    private func handleDraftReply(_ t: String) {
        guard let draft = pendingDraft else { return }
        switch true {
        // "Start over" contains "start" — must be checked first.
        case t.contains("start over") || t.contains("start again")
            || t.contains("start fresh") || t.contains("from scratch")
            || t.contains("scratch that") || t.contains("do over")
            || t.contains("ulitin natin") || t.contains("simulan ulit")
            || t.contains("bagong usapan") || t.contains("sa simula"):
            pendingDraft = nil
            pendingGoal = ""
            pendingQuestion = .none
            appendKaya("Okay, fresh start. What should we make a routine for?")
            keepListening()
        case t.contains("what did you say") || t.contains("say that again")
            || t == "repeat" || t == "huh" || t == "pardon"
            || t.contains("come again") || t.contains("what was that")
            || t.contains("ulitin mo") || t.contains("ano sabi mo")
            || t.contains("anong sabi mo") || t == "ha" || t == "ha?"
            || t.contains("ano daw"):
            if let last = conversation.last(where: { $0.isKaya }) {
                appendKaya(last.text)
            }
            keepListening()
        // "restart" contains "start" — it means remake the plan, not begin it.
        case (t.contains("start") && !t.contains("restart")) || t == "yes" || t == "sure" || t == "go"
            || t.contains("begin") || t.contains("sounds good") || t.contains("looks good")
            || t.contains("let's do it") || t.contains("lets do it") || t.contains("i'm ready")
            || t == "sige" || t == "sige na" || t == "oo" || t == "opo" || t == "yes"
            || t.contains("simulan") || t.contains("umpisahan") || t.contains("tara")
            || t == "g na" || t.contains("game na") || t == "go na" || t == "tuloy":
            let routine = RoutineStore.save(draft, in: modelContext)
            offerReminderIfNew(routine)
            respondThen("Starting \u{201C}\(routine.title)\u{201D}. Take your time.") {
                pendingDraft = nil
                pendingQuestion = .none
                activeRoutine = routine
            }
        case t.contains("step") || t.contains("show") || t.contains("read")
            || t.contains("hakbang") || t.contains("ipakita") || t.contains("pakita")
            || t.contains("basahin"):
            let list = draft.steps.enumerated()
                .map { "\($0.offset + 1). \($0.element.title)" }
                .joined(separator: "\n")
            appendKaya("Here are the steps:\n\(list)")
            keepListening()
        case t.contains("again") || t.contains("different") || t.contains("redo")
            || t.contains("restart") || t.contains("try again") || t.contains("not quite")
            || t.contains("another version")
            || t.contains("make another") || t.contains("something else")
            || t == "ulit" || t == "iba" || t.contains("iba naman") || t.contains("ibang")
            || t.contains("hindi ganito") || t.contains("gusto ko iba"):
            pendingDraft = nil
            pendingQuestion = .none
            let goal = pendingGoal.isEmpty
                ? (draft.goal.isEmpty ? draft.title : draft.goal)
                : pendingGoal
            generateInConversation(goal)
        case t.contains("edit") || t.contains("change") || t.contains("revise")
            || t.contains("tweak") || t.contains("adjust") || t.contains("fix")
            || t.contains("shorter") || t.contains("longer") || t.contains("simpler")
            || t.contains("easier") || t.contains("add ") || t.contains("remove")
            || t.contains("swap") || t.contains("baguhin") || t.contains("ayusin")
            || t.contains("palitan") || t.contains("dagdagan") || t.contains("tanggalin")
            || t.contains("bawasan") || t.contains("mas madali") || t.contains("mas maikli")
            || t.contains("mas mahaba") || t.contains("alisin") || t.contains("gawing"):
            let barePhrases = ["edit", "edit it", "change", "change it", "revise",
                               "revise it", "revise the plan", "tweak it", "fix it",
                               "adjust it", "edit the steps", "change the steps"]
            if !barePhrases.contains(t), aiService.availability == .available {
                // A real instruction ("revise step two", "make it shorter") —
                // let the on-device model apply it in place.
                editDraftInConversation(draft: draft, instruction: t, opening: "On it — updating the plan.")
            } else {
                // No instruction, or the model is off — hand over the editor.
                respondThen("Opening the editor — change anything you like.") {
                    pendingDraft = nil
                    pendingQuestion = .none
                    voiceRoute = .review(draft)
                }
            }
        case t.contains("never mind") || t.contains("cancel") || t.contains("stop")
            || t.contains("forget it") || t.contains("forget that") || t.contains("don't save")
            || t.contains("leave it") || t.contains("drop it") || t.contains("delete it")
            || t.contains("huwag na") || t.contains("wag na") || t.contains("ayaw ko")
            || t.contains("balewala") || t.contains("kalimutan") || t.contains("itigil")
            || t == "hindi na" || t == "di na":
            pendingDraft = nil
            pendingGoal = ""
            pendingQuestion = .none
            appendKaya("Okay — I won't save it. Tell me another goal anytime.")
            keepListening()
        case pendingQuestion == .repeatRule || pendingQuestion == .scheduleTime:
            // Offline path — the model wasn't asked, so a non-answer just
            // re-asks the open question instead of falling through.
            if !applyScheduleAnswer(t) { reaskScheduleQuestion() }
        default:
            // A new sentence mid-draft is most likely a new goal.
            pendingDraft = nil
            routeAndRespond(t)
        }
    }

    // MARK: - Scheduling questions

    /// First answer: how often should it come back?
    /// First pass at a scheduling reply — exact parsers only. False means
    /// the message wasn't a schedule answer at all; the caller decides
    /// whether the model or a re-ask handles it.
    private func applyScheduleAnswer(_ t: String) -> Bool {
        guard pendingDraft != nil else { return false }
        switch pendingQuestion {
        case .repeatRule: return applyRepeatAnswer(t)
        case .scheduleTime: return applyTimeAnswer(t)
        default: return false
        }
    }

    /// Offline/no-parse path — politely ask the open schedule question again.
    private func reaskScheduleQuestion() {
        switch pendingQuestion {
        case .repeatRule:
            appendKaya("Sorry — say \u{201C}just once\u{201D}, \u{201C}every day\u{201D}, \u{201C}every week\u{201D}, or a day like \u{201C}Mondays\u{201D}.")
        case .scheduleTime:
            appendKaya("Say a time like \u{201C}8 am\u{201D} or \u{201C}in the morning\u{201D}, a day like \u{201C}Friday\u{201D}, or \u{201C}no schedule\u{201D}.")
        default:
            appendKaya("I didn't quite get that — try again, or tap a suggestion.")
        }
        keepListening()
    }

    private func applyRepeatAnswer(_ t: String) -> Bool {
        guard var draft = pendingDraft else { return false }
        if t.contains("every day") || t.contains("daily") || t.contains("araw-araw")
            || t.contains("bawat araw") || t.contains("pang-araw") || t.contains("kada araw")
            || t.contains("everyday") {
            draft.repeatRule = .daily
            pendingDraft = draft
            askTime()
        } else if let weekday = weekdayNamed(in: t) {
            draft.repeatRule = .weekly
            draft.scheduledWeekday = weekday
            draft.scheduledDate = KayaSchedule.nextDate(weekday: weekday)
            pendingDraft = draft
            askTime()
        } else if t.contains("week") || t.contains("linggo") || t.contains("lingguhan") {
            draft.repeatRule = .weekly
            draft.scheduledWeekday = Calendar.current.component(.weekday, from: Date())
            pendingDraft = draft
            askTime()
        } else if t.contains("once") || t == "no" || t.contains("don't")
            || t.contains("isang beses") || t.contains("minsan lang") || t.contains("isa lang") {
            draft.repeatRule = .none
            pendingDraft = draft
            pendingQuestion = .scheduleTime
            appendKaya("Just once. Do you want to plan a day or time for it? Say something like \u{201C}Friday at 8 am\u{201D}, \u{201C}tomorrow\u{201D}, or \u{201C}no schedule\u{201D}.")
            keepListening()
        } else if t.contains("skip") || t.contains("later") || t.contains("mamaya na")
            || t.contains("bahala na") {
            finishScheduling()
        } else {
            return false
        }
        return true
    }

    private func askTime() {
        pendingQuestion = .scheduleTime
        appendKaya("Got it. What time of day? Say something like \u{201C}8 am\u{201D}, \u{201C}in the morning\u{201D}, or \u{201C}any time\u{201D}.")
        keepListening()
    }

    /// Second answer: a time of day, a day for one-off plans, or none.
    /// Returns false when nothing parsed — an unmatched message is a side
    /// question or chat, not a silent "no schedule".
    private func applyTimeAnswer(_ t: String) -> Bool {
        guard var draft = pendingDraft else { return false }
        if t.contains("any time") || t.contains("no time") || t.contains("no schedule") || t.contains("whenever")
            || t.contains("kahit anong oras") || t.contains("kahit kelan") || t.contains("kahit kailan")
            || t.contains("walang oras") || t == "basta" {
            draft.scheduledMinutes = nil
            pendingDraft = draft
            finishScheduling()
            return true
        }
        var matched = false
        if t.contains("tomorrow") || t.contains("bukas") {
            draft.scheduledDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
            matched = true
        } else if let weekday = weekdayNamed(in: t) {
            if draft.repeatRule == .weekly {
                draft.scheduledWeekday = weekday
            }
            draft.scheduledDate = KayaSchedule.nextDate(weekday: weekday)
            matched = true
        } else if t.contains("today") || t.contains("ngayon") || t.contains("mamaya"),
                  draft.scheduledDate == nil {
            draft.scheduledDate = Date()
            matched = true
        }
        if let minutes = minutesNamed(in: t) ?? Tagalog.minutesNamed(in: t) {
            draft.scheduledMinutes = minutes
            matched = true
            // One-off plans with a time get a concrete date.
            if draft.repeatRule == .none, draft.scheduledDate == nil {
                var date = Calendar.current.startOfDay(for: Date())
                date = Calendar.current.date(byAdding: .minute, value: minutes, to: date) ?? date
                if date < Date() {
                    date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
                }
                draft.scheduledDate = date
            }
        }
        guard matched else { return false }
        pendingDraft = draft
        finishScheduling()
        return true
    }

    /// Wrap-up once scheduling is settled — the draft stays saved-ready.
    private func finishScheduling() {
        guard let draft = pendingDraft else { return }
        pendingQuestion = .none
        let phrase = KayaSchedule.describe(
            repeatRule: draft.repeatRule, weekday: draft.scheduledWeekday,
            date: draft.scheduledDate, minutes: draft.scheduledMinutes)
        if draft.repeatRule != .none || draft.scheduledDate != nil || draft.scheduledMinutes != nil {
            appendKaya("All set — \u{201C}\(draft.title)\u{201D}, \(phrase.lowercased()). Say \u{201C}start it\u{201D} to begin now, or find it on your calendar in Routines.")
        } else {
            appendKaya("All set — no schedule for \u{201C}\(draft.title)\u{201D}. Say \u{201C}start it\u{201D} when you're ready.")
        }
        keepListening()
    }

    /// Finds a weekday name inside a reply — English ("mondays") or
    /// Tagalog ("tuwing lunes", "sa biyernes").
    private func weekdayNamed(in t: String) -> Int? {
        for (index, name) in KayaSchedule.weekdaySymbols.enumerated() {
            let lower = name.lowercased()
            if t.contains(lower) || t.contains(lower + "s") { return index + 1 }
        }
        return Tagalog.weekdayNamed(in: t)
    }

    /// Finds a time of day in a reply: "8 am", "17:30", "in the morning".
    /// Bare digits count ("at 8") — but a number measuring a duration is
    /// not a clock time, so "in 2 days" must not match 2:00.
    private func minutesNamed(in t: String) -> Int? {
        if t.contains("morning") { return 8 * 60 }
        if t.contains("noon") || t.contains("midday") { return 12 * 60 }
        if t.contains("afternoon") { return 14 * 60 }
        if t.contains("evening") { return 18 * 60 }
        if t.contains("night") { return 20 * 60 }
        let durationUnit = #/^(days?|weeks?|hours?|hrs?|minutes?|mins?|months?|times|araw|linggo|oras|minuto|beses)\b/#
        for match in t.matches(of: #/(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?/#) {
            guard let hourRaw = Int(match.1) else { continue }
            // Skip duration counts: "2 days", "every 3 weeks", "12 hours".
            if match.3 == nil,
               t[match.range.upperBound...].drop(while: \.isWhitespace)
                   .lowercased().firstMatch(of: durationUnit) != nil {
                continue
            }
            var hour = hourRaw
            let minute = match.2.flatMap { Int($0) } ?? 0
            let meridiem = (match.3.map(String.init) ?? "").lowercased()
            if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
            guard (0..<24).contains(hour), (0..<60).contains(minute) else { continue }
            return hour * 60 + minute
        }
        return nil
    }

    /// True when the spoken text contains the title, the title contains it,
    /// or a meaningful word from the title appears in the speech.
    private func titleMatches(_ title: String, in spoken: String) -> Bool {
        let lowered = title.lowercased()
        if spoken.count > 3 && (spoken.contains(lowered) || lowered.contains(spoken)) { return true }
        let stopWords: Set<String> = ["with", "your", "the", "for", "and", "you"]
        return lowered
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 && !stopWords.contains($0) }
            .contains { spoken.contains($0) }
    }
}
