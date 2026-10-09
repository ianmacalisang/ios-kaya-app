//
//  SpeechService.swift
//  Kaya
//
//  On-device speech via AVSpeechSynthesizer. No network required.
//

import AVFoundation
import Foundation

@Observable
final class SpeechService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var activeUtterance: AVSpeechUtterance?
    /// Replies waiting behind the current utterance — back-to-back chat
    /// bubbles queue up instead of cutting each other off mid-word.
    private var queue: [(text: String, languageCode: String, onFinish: (() -> Void)?)] = []

    /// Preferred voices per language, resolved once — premium/enhanced
    /// voices sound noticeably more natural than the compact default.
    private var preferredVoices: [String: AVSpeechSynthesisVoice] = [:]

    var isSpeaking: Bool { synthesizer.isSpeaking }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Picks the best installed voice for a BCP-47 code — premium first,
    /// then enhanced, then whatever the system offers for that language.
    private func bestVoice(for bcp47: String) -> AVSpeechSynthesisVoice? {
        if let cached = preferredVoices[bcp47] { return cached }
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(bcp47) || $0.language == bcp47 }
        let best = candidates.first(where: { $0.quality == .premium })
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: bcp47)
        if let best { preferredVoices[bcp47] = best }
        return best
    }

    /// Cleanup so the synthesizer reads it well: drop glyphs it would try
    /// to pronounce (quotes, bullets, asterisks), turn dashes and ellipses
    /// into natural pauses, drop parenthetical asides, collapse whitespace,
    /// and make sure the line ends in a full stop for a natural landing.
    private func cleaned(_ text: String) -> String {
        var s = text
            // Parenthetical notes are for the screen, not the ear.
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            // Visual-only glyphs — keep apostrophes so contractions survive.
            .replacingOccurrences(of: "[\"“”«»•*_#]", with: "", options: .regularExpression)
            // Dashes and ellipses are pauses, not words.
            .replacingOccurrences(of: "…", with: ", ")
            .replacingOccurrences(of: "[–—]", with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !s.hasSuffix(".") && !s.hasSuffix("!") && !s.hasSuffix("?") {
            s += "."
        }
        return s
    }

    /// Speak text aloud. `onFinish` runs when the utterance completes naturally —
    /// it is discarded if speech is stopped early.
    /// `queue: true` chains behind a line still playing instead of cutting it
    /// off — chat replies use this; commands and narration interrupt as before.
    func speak(_ text: String, languageCode: String = "en",
               queue: Bool = false, onFinish: (() -> Void)? = nil) {
        let cleanedText = cleaned(text)
        if queue && (synthesizer.isSpeaking || synthesizer.isPaused) {
            self.queue.append((cleanedText, languageCode, onFinish))
            return
        }
        startUtterance(cleanedText, languageCode: languageCode, onFinish: onFinish)
    }

    /// Interrupts whatever is playing — but deliberately leaves `queue`
    /// alone so pending replies still get said after this line.
    private func startUtterance(_ cleanedText: String, languageCode: String,
                                onFinish: (() -> Void)?) {
        self.onFinish = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard !cleanedText.isEmpty else {
            onFinish?()
            return
        }
        self.onFinish = onFinish

        let utterance = AVSpeechUtterance(string: cleanedText)
        let bcp47 = languageCode == "fil" ? "fil-PH" : "en-US"
        utterance.voice = bestVoice(for: bcp47)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        // Diction: a touch slower than default so instructions land clearly,
        // gentle pitch for warmth, and small pauses around the utterance so
        // phrases don't blur together.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 1.05
        utterance.preUtteranceDelay = 0.12
        utterance.postUtteranceDelay = 0.25
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = true

        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        queue.removeAll()
        onFinish = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtterance.map({ ObjectIdentifier($0) }) == utteranceID else { return }
            self.activeUtterance = nil
            let callback = self.onFinish
            self.onFinish = nil
            // Start the next queued reply first — its own finish callback
            // can then see whether the mic is free to come back.
            if let next = self.queue.first {
                self.queue.removeFirst()
                self.startUtterance(next.text, languageCode: next.languageCode,
                                    onFinish: next.onFinish)
            }
            callback?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtterance.map({ ObjectIdentifier($0) }) == utteranceID else { return }
            self.activeUtterance = nil
            self.onFinish = nil
        }
    }
}
