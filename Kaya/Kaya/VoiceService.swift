//
//  VoiceService.swift
//  Kaya
//
//  On-device speech recognition (SFSpeechRecognizer), a voice-command
//  parser, and the animated listening orb. Recognition is forced on-device:
//  no audio leaves the phone.
//

import AVFoundation
import Speech
import SwiftUI

// MARK: - Voice commands

enum VoiceCommand: Equatable {
    case done, next, previous, repeatStep, pause, resume
    case help, somethingChanged, stop, start, skip
    case feltEasy, feltOkay, feltHard
    case simplify, overview
}

enum VoiceCommands {
    /// Match the first known command phrase in the text. Ordered so that
    /// more specific / destructive intents win over generic ones.
    static func parse(_ text: String) -> VoiceCommand? {
        let t = " " + text.lowercased() + " "
        // Bilingual table — English and Tagalog are always both active, so
        // Taglish sentences match whichever half is there.
        let table: [(VoiceCommand, [String])] = [
            (.somethingChanged, ["something changed", " changed", "plan changed", "different",
                                 "nagbago", "may nagbago", "iba na", "nag iba"]),
            (.simplify, ["simpler", "break it down", "smaller steps", "too hard", "too much", "easier",
                         "mas madali", "mas maliit", "hirap ako", "di ko kaya", "hindi ko kaya"]),
            (.overview, ["all steps", "show steps", "the steps", "the list", "where am i",
                         "what's next", "whats next", "how many steps", "step list",
                         "mga steps", "mga hakbang", "lahat ng step", "saan na ako",
                         "ano susunod", "anong susunod"]),
            (.stop, ["stop", "cancel", "quit", "exit", "enough",
                     "tama na", "itigil", "tigil", "ayaw ko na"]),
            (.help, ["help", "i need help", "tulong", "tulungan", "tulong po"]),
            (.pause, ["pause", "hold on", "wait", "break",
                      "sandali", "teka", "hintay", "hintayin", "hintay muna"]),
            (.resume, ["resume", "continue", "keep going", "go on",
                       "ituloy", "tuloy", "sige", "sige na", "tuloy lang"]),
            (.repeatStep, ["repeat", "again", "say that", "explain",
                           "ulitin", "ulit", "paki ulit", "ulitin mo", "ano ulit"]),
            (.previous, ["previous", "go back", "last step", " back",
                         "babalik", "bumalik", "nakaraan", "bawiin", "bawi"]),
            (.skip, ["skip", "pass", "not now", "laktawan", "sa susunod na lang"]),
            (.start, ["start", "begin", "let's go", "lets go", "go ahead",
                      "simulan", "umpisahan", "sige na", "tara", "tara na", "g na", "game na"]),
            (.done, ["done", "did it", "finished", "complete", "next", "all done",
                     "tapos", "tapos na", "natapos", "okay na", "ok na", "susunod", "done na"]),
            (.feltEasy, ["easy", "it was easy", "simple", "madali", "madali lang", "dali lang"]),
            (.feltOkay, ["okay", "fine", "it was okay", "so so", "okay lang", "ok lang", "pwede na"]),
            (.feltHard, ["hard", "difficult", "tough", "it was hard",
                         "mahirap", "ang hirap", "hirap talaga", "nahirapan"]),
        ]
        for (command, phrases) in table {
            if phrases.contains(where: { t.contains($0) }) {
                return command
            }
        }
        return nil
    }
}

// MARK: - Voice service

@Observable
final class VoiceService: NSObject {
    private(set) var isListening = false
    private(set) var isAuthorized = false
    private(set) var permissionDenied = false
    private(set) var isUnsupported = false

    /// Everything heard since `markHandled()` was last called.
    private(set) var transcript = ""

    /// "en" or "fil" — detected per transcript by scoring Tagalog marker
    /// words (there is no Filipino recognizer to ask). en-PH transcription
    /// produces real Tagalog tokens, which is what makes this workable.
    private(set) var detectedLanguage = "en"
    private var handledLength = 0

    /// Unhandled tail of the transcript — the "new" words to react to.
    var unhandled: String {
        guard handledLength <= transcript.count else { return transcript }
        return String(transcript.dropFirst(handledLength))
            .trimmingCharacters(in: .whitespaces)
    }

    var onTranscript: (() -> Void)?

    /// Philippine English first — it transcribes Taglish and Filipino-
    /// accented English more faithfully than en-US, and plain English still
    /// works. (Verified on-device: no fil/tl recognizer exists in the SDK.)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-PH"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var wantsListening = false
    private var consecutiveFailures = 0

    /// Seconds of silence before the mic turns itself off. 0 means stay on
    /// (the default — the task player waits patiently through long steps).
    /// The chat sets a timeout so the mic is never hot when nobody's talking.
    var idleTimeoutSeconds: TimeInterval = 0
    private var lastHeardAt = Date()
    private var idleWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        if recognizer?.supportsOnDeviceRecognition == false {
            isUnsupported = true
        }
    }

    /// Ask for Speech + Microphone permission once. Returns false if refused.
    @discardableResult
    func enable() async -> Bool {
        guard !isUnsupported else { return false }
        if isAuthorized { return true }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else {
            permissionDenied = true
            return false
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()

        isAuthorized = micGranted
        permissionDenied = !isAuthorized
        return isAuthorized
    }

    func startListening() {
        wantsListening = true
        guard let recognizer, isAuthorized, !isUnsupported, !isListening else { return }

        teardownRecognition()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.defaultToSpeaker, .duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true
        newRequest.shouldReportPartialResults = true
        request = newRequest
        transcript = ""
        detectedLanguage = "en"
        handledLength = 0

        recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.detectedLanguage = Tagalog.isTagalog(self.transcript) ? "fil" : "en"
                    self.lastHeardAt = Date()
                    self.onTranscript?()
                }
                if error != nil {
                    self.consecutiveFailures += 1
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardownRecognition()
                    self.restartIfWanted()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let capturedRequest = newRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            capturedRequest.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            consecutiveFailures = 0
            lastHeardAt = Date()
            armIdleWatchdog()
        } catch {
            consecutiveFailures += 1
            teardownRecognition()
            restartIfWanted()
        }
    }

    func stopListening() {
        wantsListening = false
        consecutiveFailures = 0
        teardownRecognition()
    }

    /// Mark everything heard so far as consumed, so it isn't re-parsed.
    func markHandled() {
        handledLength = transcript.count
    }

    private func restartIfWanted() {
        guard wantsListening, !isListening, consecutiveFailures < 3 else {
            wantsListening = false
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if wantsListening, !isListening {
                startListening()
            }
        }
    }

    /// Stops the mic after `idleTimeoutSeconds` without a transcript update —
    /// the mic is never left recording when it isn't being used.
    private func armIdleWatchdog() {
        idleWatchdog?.cancel()
        guard idleTimeoutSeconds > 0 else { return }
        idleWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isListening else { return }
                if Date().timeIntervalSince(self.lastHeardAt) >= self.idleTimeoutSeconds {
                    self.stopListening()
                    return
                }
            }
        }
    }

    private func teardownRecognition() {
        idleWatchdog?.cancel()
        idleWatchdog = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}

// MARK: - Listening orb

struct VoiceOrb: View {
    let isListening: Bool
    let isSpeaking: Bool
    var size: CGFloat = 84
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var attract = false

    /// Soft "this is tappable" cue — only while idle.
    private var idle: Bool { !isListening && !isSpeaking }

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(KayaTheme.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: size, height: size)
                        .scaleEffect(pulse ? 1.8 : 1.0)
                        .opacity(pulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.7)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.85),
                            value: pulse
                        )
                        .opacity(isListening && !reduceMotion ? 1 : 0)
                }
                // Idle ping — a faint ring drifts outward so the orb reads
                // as a live, tappable control even before first use.
                Circle()
                    .stroke(KayaTheme.accent.opacity(0.25), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(attract ? 1.35 : 1.0)
                    .opacity(attract ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 1.9).repeatForever(autoreverses: false),
                        value: attract
                    )
                    .opacity(idle && !reduceMotion ? 1 : 0)
                Circle()
                    .fill(isListening ? KayaTheme.accent : KayaTheme.warm)
                    .frame(width: size, height: size)
                    .scaleEffect(isListening && !reduceMotion ? (pulse ? 1.06 : 1.0) : 1.0)
                    .animation(
                        .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulse
                    )
                    .overlay {
                        if isListening {
                            ListeningBars(color: KayaTheme.onAccent, maxHeight: size * 0.34)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: size * 0.38, weight: .semibold))
                                .foregroundStyle(KayaTheme.accent)
                                // Gentle breathing on the mic glyph itself.
                                .scaleEffect(attract ? 1.08 : 1.0)
                                .animation(
                                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                    value: attract
                                )
                        }
                    }
            }
            .frame(width: size * 1.7, height: size * 1.7)
            .contentShape(Circle())
        }
        .buttonStyle(KayaChipButtonStyle())
        .onAppear {
            pulse = isListening
            attract = idle && !reduceMotion
        }
        .onChange(of: isListening) { _, value in
            pulse = value
            attract = idle && !reduceMotion
        }
        .onChange(of: isSpeaking) { _, _ in
            attract = idle && !reduceMotion
        }
        .accessibilityLabel(isListening ? "Listening. Tap to stop." : "Voice control")
        .accessibilityHint(isListening ? "" : "Tap to talk to Kaya")
    }

    private var iconName: String {
        if isSpeaking { return "speaker.wave.2.fill" }
        return "mic.fill"
    }
}

/// Animated sound bars shown inside the orb while listening.
private struct ListeningBars: View {
    let color: Color
    var maxHeight: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private static let heights: [(CGFloat, CGFloat)] = [
        (0.30, 0.65), (0.45, 1.0), (0.30, 0.80), (0.50, 0.90), (0.30, 0.60)
    ]
    private static let durations: [Double] = [0.50, 0.42, 0.62, 0.48, 0.56]

    var body: some View {
        HStack(spacing: maxHeight * 0.18) {
            ForEach(0..<Self.heights.count, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(
                        width: maxHeight * 0.16,
                        height: maxHeight * (animating ? Self.heights[index].1 : Self.heights[index].0)
                    )
                    .animation(
                        .easeInOut(duration: Self.durations[index])
                            .repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .accessibilityHidden(true)
        .onAppear { animating = !reduceMotion }
    }
}
