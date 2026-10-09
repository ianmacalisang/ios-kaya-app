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
    /// UI-facing "voice won't work" flag — either a permanent recognizer
    /// limitation or no usable mic *right now*. The mic half is re-probed
    /// on every deliberate tap, so plugging in a headset mid-session works.
    private(set) var isUnsupported = false
    /// No on-device recognizer at all — this can't change at runtime.
    private var recognizerUnavailable = false

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
    /// works. But Kaya never sends audio off-device, so the recognizer must
    /// support on-device mode: en-PH exists on real hardware but is often
    /// network-only, which would make every orb tap dead. Fall back to
    /// en-US, which always has an on-device model.
    private let recognizer: SFSpeechRecognizer? = {
        for code in ["en-PH", "en-US"] {
            if let candidate = SFSpeechRecognizer(locale: Locale(identifier: code)) {
                NSLog("Kaya Voice: %@ recognizer exists, on-device=%d",
                      code, candidate.supportsOnDeviceRecognition)
                if candidate.supportsOnDeviceRecognition { return candidate }
            } else {
                NSLog("Kaya Voice: %@ recognizer unavailable", code)
            }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var wantsListening = false
    private var consecutiveFailures = 0
    /// Words heard before a mid-listen session restart — the recognizer
    /// ends itself after ~60s, and without this carry-over everything
    /// said before the boundary would vanish.
    private var transcriptPrefix = ""

    /// Seconds of silence before the mic turns itself off. 0 means stay on
    /// (the default — the task player waits patiently through long steps).
    /// The chat sets a timeout so the mic is never hot when nobody's talking.
    var idleTimeoutSeconds: TimeInterval = 0
    private var lastHeardAt = Date()
    private var idleWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        // nil recognizer counts too — `nil == false` would slip past a
        // plain supportsOnDeviceRecognition check and fail silently.
        recognizerUnavailable = recognizer == nil
            || recognizer?.supportsOnDeviceRecognition == false
        isUnsupported = recognizerUnavailable
        if recognizerUnavailable {
            NSLog("Kaya Voice: no on-device recognizer — voice disabled")
        }
    }

    /// Ask for Speech + Microphone permission once. Returns false if refused.
    @discardableResult
    func enable() async -> Bool {
        // Gate on the permanent check only — a missing mic is re-probed
        // in startListening each time the user asks.
        guard !recognizerUnavailable else { return false }
        if isAuthorized { return true }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                NSLog("Kaya Voice: speech authorization -> %d", status.rawValue)
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else {
            permissionDenied = true
            return false
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        NSLog("Kaya Voice: mic permission -> %d", micGranted)

        isAuthorized = micGranted
        permissionDenied = !isAuthorized
        return isAuthorized
    }

    func startListening() {
        // A deliberate start re-probes the input — a mic plugged in after
        // launch must not stay dead just because earlier probes failed.
        let freshRequest = !wantsListening
        wantsListening = true
        if freshRequest { consecutiveFailures = 0 }
        guard let recognizer, isAuthorized, !recognizerUnavailable, !isListening else { return }

        teardownRecognition()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .duckOthers])
        } catch {
            NSLog("Kaya Voice: setCategory failed — %@", error.localizedDescription)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("Kaya Voice: setActive failed — %@", error.localizedDescription)
        }
        audioEngine.prepare()

        // Probe the input only after the record session is active — before
        // that, the format can validly report 0 Hz on a cold start.
        // No usable input = an invalid format (e.g. a simulator on a Mac
        // with no microphone). installTap raises an ObjC exception there,
        // which Swift can't catch — so check first and treat it as a
        // normal retryable failure; only if retries keep failing is voice
        // marked unavailable.
        let inputNode = audioEngine.inputNode
        var format = inputNode.outputFormat(forBus: 0)
        if format.sampleRate <= 0 {
            // The node may not have propagated the hardware format yet —
            // the input side reports what the hardware actually offers.
            format = inputNode.inputFormat(forBus: 0)
        }
        NSLog("Kaya Voice: probe rate=%.0f ch=%d, inputAvailable=%d, inputs=%d, route=%@",
              format.sampleRate, format.channelCount,
              session.isInputAvailable, session.inputNumberOfChannels,
              session.currentRoute.inputs.map { $0.portName }.joined(separator: ","))
        guard format.sampleRate > 0, format.channelCount > 0 else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { isUnsupported = true }
            restartIfWanted()
            return
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true
        newRequest.shouldReportPartialResults = true
        request = newRequest
        transcript = transcriptPrefix
        detectedLanguage = "en"
        // handledLength survives restarts: it indexes into the preserved
        // prefix, so `unhandled` still means "not yet reacted to".
        if transcript.isEmpty { handledLength = 0 }

        recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    // This session's words append to whatever was heard
                    // before a mid-listen restart.
                    let heard = result.bestTranscription.formattedString
                    self.transcript = self.transcriptPrefix.isEmpty
                        ? heard
                        : self.transcriptPrefix + " " + heard
                    self.detectedLanguage = Tagalog.isTagalog(self.transcript) ? "fil" : "en"
                    self.lastHeardAt = Date()
                    self.onTranscript?()
                }
                if let error {
                    NSLog("Kaya Voice: recognition error — %@", error.localizedDescription)
                    self.consecutiveFailures += 1
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardownRecognition()
                    self.restartIfWanted()
                }
            }
        }

        let capturedRequest = newRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            capturedRequest.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            consecutiveFailures = 0
            isUnsupported = recognizerUnavailable
            lastHeardAt = Date()
            armIdleWatchdog()
        } catch {
            NSLog("Kaya Voice: engine start failed — %@", error.localizedDescription)
            consecutiveFailures += 1
            teardownRecognition()
            restartIfWanted()
        }
    }

    func stopListening() {
        wantsListening = false
        consecutiveFailures = 0
        teardownRecognition()
        // A deliberate stop ends the utterance epoch — the next session
        // starts clean rather than resurrecting old words.
        transcriptPrefix = ""
        handledLength = 0
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
        // Freeze what was heard — the next session prepends it so a
        // mid-sentence restart (the ~60s recognizer limit, an error)
        // doesn't drop the earlier words.
        let carry = transcript
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if wantsListening, !isListening {
                transcriptPrefix = carry
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
