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
    /// Playback fraction 0…1. Intentionally NOT `@Published`: cloud/Apple
    /// providers push this many times per second, and publishing it re-renders
    /// every SwiftUI observer (settings, menu bar) through macOS 26's
    /// DesignLibrary path, which has been crashing via MainActor checks.
    /// The AppKit indicator reads this directly instead.
    private(set) var progress: Double = 0.0
    @Published private(set) var currentText: String = ""

    // MARK: - Dependencies (lazy, so we don't spin up AVFoundation until needed)

    private lazy var appleProvider: AppleTTSProvider = {
        let p = AppleTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        return p
    }()

    private lazy var elevenLabsProvider: ElevenLabsTTSProvider = {
        let p = ElevenLabsTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        return p
    }()

    private lazy var openAIProvider: OpenAITTSProvider = {
        let p = OpenAITTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        return p
    }()

    private lazy var geminiProvider: GeminiTTSProvider = {
        let p = GeminiTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        return p
    }()

    private var currentProviderRef: TextToSpeechProvider?
    private var playbackTask: Task<Void, Never>?
    private lazy var indicatorWindow: ReadAloudIndicatorWindow = ReadAloudIndicatorWindow(manager: self)
    private var messagePanel: NSPanel?

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

        // Capture text BEFORE publishing state or showing UI. Publishing first
        // + Accessibility work has been crashing SwiftData @Query layout in the
        // main window on macOS 26 (MainActor executor check / HIE).
        Task { @MainActor in
            let text = await SelectedTextService.fetchSelectedTextForReadAloud()
            // Let the run loop settle after any Accessibility / menu-copy work.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)

            guard let text, !text.isEmpty else {
                self.logger.info("readSelectedText: no selection")
                self.showReadAloudMessage(String(localized: "No text is selected"))
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
                self.showReadAloudMessage(String(localized: "Screen recording permission is required"))
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
                    self.showReadAloudMessage(String(localized: "No text detected in the selected region"))
                    self.state = .idle
                    return
                }
                await self.speak(text)
            case .failed(let reason):
                self.showReadAloudMessage(
                    String(format: String(localized: "Screen capture failed: %@"), reason)
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
        setProgress(0)
        currentText = ""
        state = .idle
        indicatorWindow.hide()
    }

    /// Updates the playback fraction and refreshes only the AppKit indicator.
    private func setProgress(_ value: Double) {
        progress = value
        indicatorWindow.progressDidChange()
    }

    /// AppKit-only toast — never mounts SwiftUI/`NSHostingView` (those re-enter
    /// SwiftData MainActor checks and crash on macOS 26 after Accessibility work).
    private func showReadAloudMessage(_ message: String) {
        messagePanel?.orderOut(nil)
        messagePanel = nil

        let width: CGFloat = 340
        let height: CGFloat = 44
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        box.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        panel.contentView = box

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 72))
        }
        panel.orderFrontRegardless()
        messagePanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.messagePanel === panel {
                self?.messagePanel = nil
            }
        }
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
        case .gemini:
            provider = geminiProvider
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
                self?.showReadAloudMessage(
                    String(format: String(localized: "Read-aloud failed: %@"), error.localizedDescription)
                )
            }

            // If we're still the active task (i.e. stop() didn't already fire), reset state.
            guard let self else { return }
            if self.currentProviderRef === provider {
                self.state = .idle
                self.setProgress(0)
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
