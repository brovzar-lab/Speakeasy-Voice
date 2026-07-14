import Foundation
import AVFoundation
import AppKit

/// Configuration payload passed to any `TextToSpeechProvider` when speaking.
///
/// Keeps provider-specific tuning (rate, pitch, voice identifier) out of the
/// `ReadAloudManager` so switching providers is a single value swap.
struct VoiceConfiguration {
    /// Provider-specific voice identifier.
    /// - Apple: `AVSpeechSynthesisVoice.identifier`
    /// - ElevenLabs: voice_id
    /// - OpenAI: voice name (e.g. "alloy", "nova")
    var voiceIdentifier: String?
    /// Playback rate. 1.0 = natural speed. Providers clamp to their own ranges.
    var rate: Float = 1.0
    /// Pitch multiplier (Apple only). 0.5–2.0.
    var pitch: Float = 1.0
    /// Volume (0.0–1.0).
    var volume: Float = 1.0
    /// BCP-47 language hint (e.g. "en-US", "es-MX"). Used when the identifier is nil.
    var languageCode: String?
}

enum PlaybackSeekTarget {
    static func seconds(
        current: TimeInterval,
        duration: TimeInterval,
        delta: TimeInterval
    ) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(duration, max(0, current + delta))
    }

    static func characterOffset(
        current: Int,
        textCount: Int,
        deltaSeconds: TimeInterval,
        rate: Float
    ) -> Int {
        guard textCount > 0 else { return 0 }
        let estimatedCharactersPerSecond = 15.0 * Double(max(0.5, min(2.0, rate)))
        let deltaCharacters = Int((deltaSeconds * estimatedCharactersPerSecond).rounded())
        return min(textCount, max(0, current + deltaCharacters))
    }

    static func wordBoundary(
        in text: String,
        near offset: Int,
        movingForward: Bool
    ) -> Int {
        let characters = Array(text)
        var position = min(characters.count, max(0, offset))

        if movingForward {
            while position < characters.count, !characters[position].isWhitespace {
                position += 1
            }
            while position < characters.count, characters[position].isWhitespace {
                position += 1
            }
        } else {
            while position > 0, !characters[position - 1].isWhitespace {
                position -= 1
            }
        }
        return position
    }
}

/// A speech provider that plays a chunk of text through the system audio output.
///
/// Implementations are expected to be main-actor-safe (Apple's synth requires it)
/// and to keep their delegate/streaming state internal.
@MainActor
protocol TextToSpeechProvider: AnyObject {
    /// Speak the text. Returns after playback has finished OR has been stopped.
    /// Throws on network/API failures for cloud providers.
    func speak(_ text: String, voice: VoiceConfiguration) async throws
    /// Pause playback (may be a no-op for providers that cannot pause mid-stream).
    func pause()
    /// Resume playback after pause.
    func resume()
    /// Stop playback immediately. Safe to call while idle.
    func stop()
    /// Adjust playback rate mid-utterance. Semantics differ by provider:
    /// - **Apple** must restart the utterance from the last-spoken position
    ///   (the rate is baked into `AVSpeechUtterance` and can't be changed).
    /// - **Cloud (AVAudioPlayer)** applies the new rate to the current mp3 buffer
    ///   in place — no re-fetch needed.
    ///
    /// Providers that can't honor a live change should be a no-op; the manager
    /// still writes the new value into settings so the next read uses it.
    func setLiveRate(_ rate: Float)
    /// Move playback relative to its current position. Returns false when the
    /// provider is using a live stream that must be restarted by the manager.
    func seek(by seconds: TimeInterval) -> Bool
    /// Whether audio is currently being emitted.
    var isSpeaking: Bool { get }
    /// Whether playback is paused (still holding buffered audio).
    var isPaused: Bool { get }
    /// Fires with a coarse 0.0–1.0 progress estimate as speech advances.
    var onProgressUpdate: ((Double) -> Void)? { get set }
    /// Fires when playback drains its prepared audio while the next section loads.
    var onBufferingUpdate: ((Bool) -> Void)? { get set }
}

extension TextToSpeechProvider {
    func seek(by seconds: TimeInterval) -> Bool { false }
}

// MARK: - Apple (local) provider

/// Local text-to-speech via `AVSpeechSynthesizer`.
///
/// Uses whichever voice the user picks (premium / enhanced voices sound noticeably
/// better and are downloadable from System Settings > Accessibility > Spoken Content).
/// Kept fully local — no network, no API keys.
@MainActor
final class AppleTTSProvider: NSObject, TextToSpeechProvider, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false

    /// Full text of the currently-playing utterance. Preserved so we can
    /// restart at a new rate from wherever we've spoken up to.
    private var originalText: String = ""
    /// Character offset within `originalText` where the current utterance began.
    /// Non-zero after a rate-change restart, since we resumed from part-way through.
    private var baseOffset: Int = 0
    /// Furthest character position within `originalText` we've heard the synth
    /// announce so far. Read from the delegate's `willSpeakRangeOfSpeechString`.
    private var lastSpokenOffset: Int = 0
    /// The voice config we started with — needed for restart so we keep the
    /// same voice / pitch when only rate changes.
    private var currentVoice: VoiceConfiguration?
    /// Internal restarts intentionally cancel one utterance without ending the
    /// logical read. Count callbacks so rapid seek/rate clicks remain safe.
    private var suppressedCancellationCallbacks = 0

    var onProgressUpdate: ((Double) -> Void)?
    var onBufferingUpdate: ((Bool) -> Void)?

    var isSpeaking: Bool { synthesizer.isSpeaking && !synthesizer.isPaused }
    var isPaused: Bool { synthesizer.isPaused }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: VoiceConfiguration) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCancelled = false
        suppressedCancellationCallbacks = 0
        originalText = trimmed
        baseOffset = 0
        lastSpokenOffset = 0
        currentVoice = voice

        // Record the read even for the local (zero-cost) provider so aggregate
        // stats like "reads today" and "most used voice" cover Apple usage too.
        ReadAloudUsageTracker.shared.record(
            provider: "apple",
            model: "AVSpeechSynthesizer",
            voiceId: voice.voiceIdentifier ?? "system-default",
            characterCount: trimmed.count
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.enqueueUtterance(startingAtOffset: 0, voice: voice)
        }
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else {
            resolveContinuation()
            return
        }
        isCancelled = true
        suppressedCancellationCallbacks = 0
        synthesizer.stopSpeaking(at: .immediate)
        // Delegate `didCancel` will fire and resolve the continuation.
    }

    func setLiveRate(_ rate: Float) {
        // Nothing to do if we're not actively speaking a real utterance.
        guard !originalText.isEmpty, var voice = currentVoice else { return }
        guard synthesizer.isSpeaking || synthesizer.isPaused else {
            // Not currently playing — nothing to restart. Rate update is
            // handled by the manager writing to settings for next time.
            return
        }

        voice.rate = rate
        currentVoice = voice

        // Snap the restart to a word boundary at/after the last-spoken offset so
        // we don't hear a syllable duplicate. The synth reports offsets that align
        // to word starts already, but we clamp defensively.
        let restartOffset = min(originalText.count, max(0, lastSpokenOffset))

        // If we're already at (or past) the end, don't bother restarting.
        guard restartOffset < originalText.count else { return }

        // Suppress the "did cancel" path from resolving the outer continuation
        // — we're just swapping utterances, playback is still logically ongoing.
        suppressedCancellationCallbacks += 1
        synthesizer.stopSpeaking(at: .immediate)
        enqueueUtterance(startingAtOffset: restartOffset, voice: voice)
    }

    func seek(by seconds: TimeInterval) -> Bool {
        guard !originalText.isEmpty,
              let voice = currentVoice,
              synthesizer.isSpeaking || synthesizer.isPaused else {
            return false
        }

        let target = PlaybackSeekTarget.characterOffset(
            current: max(baseOffset, lastSpokenOffset),
            textCount: originalText.count,
            deltaSeconds: seconds,
            rate: voice.rate
        )
        guard target < originalText.count else {
            stop()
            return true
        }

        let wasPaused = synthesizer.isPaused
        suppressedCancellationCallbacks += 1
        synthesizer.stopSpeaking(at: .immediate)
        lastSpokenOffset = target
        enqueueUtterance(startingAtOffset: target, voice: voice)
        if wasPaused {
            synthesizer.pauseSpeaking(at: .word)
        }
        onProgressUpdate?(Double(target) / Double(originalText.count))
        return true
    }

    private func enqueueUtterance(startingAtOffset offset: Int, voice: VoiceConfiguration) {
        let start = originalText.index(originalText.startIndex, offsetBy: offset)
        let remaining = String(originalText[start...])
        guard !remaining.isEmpty else {
            resolveContinuation()
            return
        }
        baseOffset = offset

        let utterance = AVSpeechUtterance(string: remaining)
        if let id = voice.voiceIdentifier, let av = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = av
        } else if let language = voice.languageCode, let av = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = av
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        utterance.rate = AppleTTSProvider.mapUserRateToAVRate(voice.rate)
        utterance.pitchMultiplier = max(0.5, min(2.0, voice.pitch))
        utterance.volume = max(0.0, min(1.0, voice.volume))

        synthesizer.speak(utterance)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resolveContinuation() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A cancel triggered by a rate-restart should NOT resolve the
            // outer continuation — the follow-up utterance is already queued.
            if self.suppressedCancellationCallbacks > 0 {
                self.suppressedCancellationCallbacks -= 1
                return
            }
            self.resolveContinuation()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let absoluteOffset = self.baseOffset + characterRange.location + characterRange.length
            self.lastSpokenOffset = absoluteOffset
            guard !self.originalText.isEmpty else { return }
            let progress = min(1.0, Double(absoluteOffset) / Double(self.originalText.count))
            self.onProgressUpdate?(progress)
        }
    }

    private func resolveContinuation() {
        continuation?.resume()
        continuation = nil
        originalText = ""
        baseOffset = 0
        lastSpokenOffset = 0
        currentVoice = nil
    }

    /// Apple's `AVSpeechUtterance.rate` uses 0.0–1.0 with `defaultSpeechRate` around 0.5.
    /// We accept a user-facing "1.0 = natural" rate and scale it around that midpoint,
    /// mapping 0.5 → half-speed, 2.0 → double-speed.
    private static func mapUserRateToAVRate(_ userRate: Float) -> Float {
        let clamped = max(0.25, min(2.5, userRate))
        let scaled = AVSpeechUtteranceDefaultSpeechRate * clamped
        return max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, scaled))
    }
}

// MARK: - Voice catalog

/// Snapshot of installed system voices, grouped for the settings UI.
struct AppleVoiceCatalog {
    struct VoiceEntry: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
        let quality: AVSpeechSynthesisVoiceQuality
        var qualityLabel: String {
            switch quality {
            case .premium: return "Premium"
            case .enhanced: return "Enhanced"
            default: return "Default"
            }
        }
    }

    let entries: [VoiceEntry]

    static func load() -> AppleVoiceCatalog {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let entries = voices.map { voice in
            VoiceEntry(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: voice.quality
            )
        }
        // Sort premium/enhanced to the top, then by language and name.
        let sorted = entries.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
        return AppleVoiceCatalog(entries: sorted)
    }
}
