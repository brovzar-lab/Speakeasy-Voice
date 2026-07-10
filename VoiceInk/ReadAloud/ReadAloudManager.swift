import Foundation
import AppKit
import OSLog
import Combine

/// Coarse playback state that drives the floating indicator and menu bar affordances.
enum ReadAloudState: Equatable {
    case idle
    case capturing         // grabbing selected text / OCR-ing screen region
    case loading           // provider is preparing audio (network for cloud)
    case speaking
    case paused
}

/// Central orchestrator for the Read Aloud feature.
///
/// Coordinates text capture (selected text or OCR'd screen region), routes it
/// through the configured `TextToSpeechProvider`, and drives the floating
/// indicator. Runs on the main actor to keep AVSpeechSynthesizer + AppKit safe.
///
/// Sibling in role to `VoiceInkEngine`, but strictly one-way: it emits audio,
/// never captures the microphone.
@MainActor
final class ReadAloudManager: ObservableObject {
    static let shared = ReadAloudManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud")

    // MARK: - Published state

    @Published private(set) var state: ReadAloudState = .idle
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var currentText: String = ""

    // MARK: - Dependencies (lazy, so we don't spin up AVFoundation until needed)

    private lazy var appleProvider: AppleTTSProvider = {
        let p = AppleTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        return p
    }()

    private lazy var elevenLabsProvider: ElevenLabsTTSProvider = {
        let p = ElevenLabsTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        return p
    }()

    private lazy var openAIProvider: OpenAITTSProvider = {
        let p = OpenAITTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        return p
    }()

    private var currentProviderRef: TextToSpeechProvider?
    private var playbackTask: Task<Void, Never>?
    private lazy var indicatorWindow: ReadAloudIndicatorWindow = ReadAloudIndicatorWindow(manager: self)

    private init() {}

    // MARK: - Public API

    /// Read whatever text the user has currently selected in the frontmost app.
    /// If no text is selected (or Accessibility is not trusted), shows a notification.
    func readSelectedText() {
        guard state == .idle else {
            // If already reading, replace what's playing with the new selection.
            stop()
            // Small delay so AVSpeechSynthesizer flushes cleanly before we queue a new utterance.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.readSelectedText()
            }
            return
        }

        state = .capturing
        indicatorWindow.show()

        Task { @MainActor in
            let text = await SelectedTextService.fetchSelectedText()
            guard let text, !text.isEmpty else {
                self.logger.info("readSelectedText: no selection")
                NotificationManager.shared.showNotification(
                    title: String(localized: "No text is selected"),
                    type: .warning,
                    duration: 2.5
                )
                self.state = .idle
                self.indicatorWindow.hide()
                return
            }
            await self.speak(text)
        }
    }

    /// Present the region selection overlay; OCR the drawn rectangle; then speak the result.
    func readScreenRegion() {
        guard state == .idle else {
            stop()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.readScreenRegion()
            }
            return
        }

        state = .capturing
        // Do NOT show the indicator here — the region overlay is the visible affordance.

        Task { @MainActor in
            let hasAccess = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
            guard hasAccess else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Screen recording permission is required"),
                    type: .warning,
                    duration: 4.0
                )
                self.state = .idle
                return
            }

            let result = await ScreenRegionSelectionController.shared.selectRegion()
            switch result {
            case .cancelled:
                self.logger.info("readScreenRegion: cancelled")
                self.state = .idle
            case .succeeded(let text):
                guard !text.isEmpty else {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "No text detected in the selected region"),
                        type: .warning,
                        duration: 3.0
                    )
                    self.state = .idle
                    return
                }
                self.indicatorWindow.show()
                await self.speak(text)
            case .failed(let reason):
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Screen capture failed: %@"), reason),
                    type: .error,
                    duration: 4.0
                )
                self.state = .idle
            }
        }
    }

    /// Speak an explicit string. Used by the settings "Preview Voice" button so
    /// the user can sample the current voice/provider without needing to select
    /// anything on screen.
    func preview(text: String) {
        guard state == .idle else {
            stop()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                self.preview(text: text)
            }
            return
        }
        Task { @MainActor in
            await self.speak(text)
        }
    }

    /// Toggle pause/resume when speaking, or stop when idle/finished.
    func togglePlayback() {
        switch state {
        case .idle, .capturing:
            return
        case .loading:
            stop()
        case .speaking:
            pause()
        case .paused:
            resume()
        }
    }

    func pause() {
        guard state == .speaking else { return }
        currentProviderRef?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        currentProviderRef?.resume()
        state = .speaking
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        currentProviderRef?.stop()
        currentProviderRef = nil
        progress = 0
        currentText = ""
        state = .idle
        indicatorWindow.hide()
    }

    /// Rate boundaries exposed here so the indicator can disable buttons at the extremes.
    static let minimumRate: Float = 0.5
    static let maximumRate: Float = 2.0
    static let rateStep: Float = 0.1

    /// Slow playback by one step. Persists to settings and applies live.
    func slower() {
        adjustRate(by: -Self.rateStep)
    }

    /// Speed up playback by one step. Persists to settings and applies live.
    func faster() {
        adjustRate(by: Self.rateStep)
    }

    private func adjustRate(by delta: Float) {
        let settings = ReadAloudSettings.shared
        let next = (settings.rate + delta).rounded(toDecimalPlaces: 2)
        let clamped = max(Self.minimumRate, min(Self.maximumRate, next))
        guard clamped != settings.rate else { return }
        settings.rate = clamped

        // Push the new rate into whatever provider is currently playing so it
        // takes effect *right now*, not just on the next read. Providers that
        // can't honor a live change treat this as a no-op.
        currentProviderRef?.setLiveRate(clamped)
    }

    // MARK: - Internal

    private func speak(_ text: String) async {
        let settings = ReadAloudSettings.shared
        let voice = settings.makeVoiceConfiguration()

        currentText = text
        state = .loading

        let provider: TextToSpeechProvider
        switch settings.provider {
        case .apple:
            provider = appleProvider
        case .elevenlabs:
            provider = elevenLabsProvider
        case .openai:
            provider = openAIProvider
        }

        currentProviderRef = provider

        // Show the indicator now that we're about to actually speak.
        indicatorWindow.show()

        // Kick off playback in a task so the manager stays responsive to stop/pause calls.
        let task = Task { @MainActor [weak self] in
            do {
                self?.state = .speaking
                try await provider.speak(text, voice: voice)
            } catch is CancellationError {
                // Cancelled by stop() — nothing to log.
            } catch {
                self?.logger.error("read-aloud playback failed: \(error.localizedDescription, privacy: .public)")
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Read-aloud failed: %@"), error.localizedDescription),
                    type: .error,
                    duration: 4.0
                )
            }

            // If we're still the active task (i.e. stop() didn't already fire), reset state.
            guard let self else { return }
            if self.currentProviderRef === provider {
                self.state = .idle
                self.progress = 0
                self.currentText = ""
                self.currentProviderRef = nil
                self.indicatorWindow.hide()
            }
        }
        playbackTask = task
    }
}

private extension Float {
    /// Snap to N decimal places so repeated +/- 0.1 doesn't drift into 1.0999999.
    func rounded(toDecimalPlaces places: Int) -> Float {
        let factor = pow(10.0, Float(places))
        return (self * factor).rounded() / factor
    }
}
