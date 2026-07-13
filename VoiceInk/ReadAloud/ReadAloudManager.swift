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
    case buffering        // waiting for the next rolling cloud section
    case paused

    var isActive: Bool { self != .idle }
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
    @Published private(set) var queueCount: Int = 0
    @Published private(set) var activeProvider: ReadAloudProvider?

    var elapsedSeconds: TimeInterval {
        guard let playbackStartedAt else { return accumulatedPlaybackSeconds }
        return accumulatedPlaybackSeconds + max(0, Date().timeIntervalSince(playbackStartedAt))
    }

    // MARK: - Dependencies (lazy, so we don't spin up AVFoundation until needed)

    private lazy var appleProvider: AppleTTSProvider = {
        let p = AppleTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        p.onBufferingUpdate = { [weak self] value in
            Task { @MainActor in self?.setBuffering(value) }
        }
        return p
    }()

    private lazy var elevenLabsProvider: ElevenLabsTTSProvider = {
        let p = ElevenLabsTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        p.onBufferingUpdate = { [weak self] value in
            Task { @MainActor in self?.setBuffering(value) }
        }
        return p
    }()

    private lazy var openAIProvider: OpenAITTSProvider = {
        let p = OpenAITTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        p.onBufferingUpdate = { [weak self] value in
            Task { @MainActor in self?.setBuffering(value) }
        }
        return p
    }()

    private lazy var geminiProvider: GeminiTTSProvider = {
        let p = GeminiTTSProvider()
        p.onProgressUpdate = { [weak self] value in
            Task { @MainActor in self?.setProgress(value) }
        }
        p.onBufferingUpdate = { [weak self] value in
            Task { @MainActor in self?.setBuffering(value) }
        }
        return p
    }()

    private var currentProviderRef: TextToSpeechProvider?
    private var playbackTask: Task<Void, Never>?
    private lazy var indicatorWindow: ReadAloudIndicatorWindow = ReadAloudIndicatorWindow(manager: self)
    private var messagePanel: NSPanel?
    private var textQueue = ReadAloudTextQueue()
    private var activeSessionID: UUID?
    private var playbackStartedAt: Date?
    private var accumulatedPlaybackSeconds: TimeInterval = 0
    private var pausedAfterPlaybackStarted = false
    private var selectionCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var playbackTransitionTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Read whatever text the user has currently selected in the frontmost app.
    /// If no text is selected (or Accessibility is not trusted), shows a notification.
    func readSelectedText() {
        // Capture text BEFORE publishing state or showing UI. Publishing first
        // + Accessibility work has been crashing SwiftData @Query layout in the
        // main window on macOS 26 (MainActor executor check / HIE).
        let captureID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.selectionCaptureTasks[captureID] = nil }
            let text = await SelectedTextService.fetchSelectedTextForReadAloud()
            guard !Task.isCancelled else { return }
            // Let the run loop settle after any Accessibility / menu-copy work.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }

            guard let text, !text.isEmpty else {
                self.logger.info("readSelectedText: no selection")
                self.showReadAloudMessage(String(localized: "No text is selected"))
                return
            }

            if self.state != .idle {
                if ReadAloudSettings.shared.enqueueSelectedText {
                    self.textQueue.enqueue(text)
                    self.queueCount = self.textQueue.count
                    self.showReadAloudMessage("Added to reading queue (\(self.queueCount))")
                    return
                }
                self.resetCurrentSession(clearQueue: true, hideIndicator: true)
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
            }
            await self.speak(text)
        }
        selectionCaptureTasks[captureID] = task
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
        case .speaking, .buffering:
            pause()
        case .paused:
            resume()
        }
    }

    func pause() {
        guard state == .speaking || state == .buffering else { return }
        if let playbackStartedAt {
            accumulatedPlaybackSeconds += max(0, Date().timeIntervalSince(playbackStartedAt))
            self.playbackStartedAt = nil
            pausedAfterPlaybackStarted = true
        }
        currentProviderRef?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        currentProviderRef?.resume()
        state = .speaking
        if pausedAfterPlaybackStarted {
            playbackStartedAt = Date()
            pausedAfterPlaybackStarted = false
        }
    }

    func stop() {
        selectionCaptureTasks.values.forEach { $0.cancel() }
        selectionCaptureTasks.removeAll()
        playbackTransitionTask?.cancel()
        playbackTransitionTask = nil
        resetCurrentSession(clearQueue: true, hideIndicator: true)
    }

    func skipToNext() {
        guard let next = textQueue.dequeue() else {
            stop()
            return
        }

        resetCurrentSession(clearQueue: false, hideIndicator: false)
        queueCount = textQueue.count

        let transition = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.playbackTransitionTask = nil
            await self.speak(next)
        }
        playbackTransitionTask = transition
    }

    private func resetCurrentSession(clearQueue: Bool, hideIndicator: Bool) {
        activeSessionID = nil
        playbackTask?.cancel()
        playbackTask = nil
        currentProviderRef?.stop()
        currentProviderRef = nil
        activeProvider = nil
        playbackStartedAt = nil
        accumulatedPlaybackSeconds = 0
        pausedAfterPlaybackStarted = false
        if clearQueue {
            textQueue.clear()
            queueCount = 0
        }
        resetProgress()
        currentText = ""
        state = .idle
        if hideIndicator { indicatorWindow.hide() }
    }

    /// Updates the playback fraction and refreshes only the AppKit indicator.
    private func setProgress(_ value: Double) {
        if playbackStartedAt == nil, state == .speaking {
            playbackStartedAt = Date()
        }
        progress = value
        indicatorWindow.progressDidChange()
    }

    private func resetProgress() {
        progress = 0
        indicatorWindow.progressDidChange()
    }

    private func setBuffering(_ isBuffering: Bool) {
        guard activeSessionID != nil, state != .idle, state != .capturing, state != .paused else { return }
        state = isBuffering ? .buffering : .speaking
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
        let segmentPlan = ReadAloudSegmentPlanner.plan(text: text)
        let primaryKind = settings.provider
        let sessionID = UUID()
        activeSessionID = sessionID

        currentText = text
        state = .loading
        activeProvider = primaryKind
        let primaryProvider = provider(for: primaryKind)
        currentProviderRef = primaryProvider
        playbackStartedAt = nil
        accumulatedPlaybackSeconds = 0
        pausedAfterPlaybackStarted = false

        // Show the indicator now that we're about to actually speak.
        indicatorWindow.show()

        // Kick off playback in a task so the manager stays responsive to stop/pause calls.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.state = .speaking
                _ = try await ReadAloudPlaybackRecovery.runSegmentAware(
                    primary: primaryKind,
                    preferredFallback: settings.fallbackProvider,
                    fallbackEnabled: settings.automaticFallbackEnabled,
                    configuredProviders: self.configuredProviders(),
                    segmentCount: segmentPlan.segments.count,
                    onFallback: { fallbackKind in
                        let fallbackProvider = self.provider(for: fallbackKind)
                        self.logger.warning("Read-aloud primary failed; continuing with fallback primary=\(primaryKind.rawValue, privacy: .public) fallback=\(fallbackKind.rawValue, privacy: .public)")
                        self.showReadAloudMessage("\(primaryKind.shortName) is unavailable. Continuing with \(fallbackKind.shortName).")
                        self.activeProvider = fallbackKind
                        self.currentProviderRef = fallbackProvider
                        self.state = .speaking
                    },
                    speak: { kind, startingSegment in
                        let selectedProvider = self.provider(for: kind)
                        try await selectedProvider.speak(
                            segmentPlan.text(fromSegment: startingSegment),
                            voice: settings.makeVoiceConfiguration(for: kind)
                        )
                    }
                )
            } catch is CancellationError {
                // Cancelled by stop() — nothing to log.
            } catch {
                let visibleProvider = self.activeProvider ?? primaryKind
                self.logger.error("read-aloud playback failed provider=\(visibleProvider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.showReadAloudMessage(
                    ReadAloudErrorPresentation.message(provider: visibleProvider, error: error)
                )
            }

            guard self.activeSessionID == sessionID else { return }
            await self.finishSession()
        }
        playbackTask = task
    }

    private func finishSession() async {
        playbackTask = nil
        currentProviderRef = nil
        activeProvider = nil
        playbackStartedAt = nil
        accumulatedPlaybackSeconds = 0
        pausedAfterPlaybackStarted = false
        resetProgress()
        currentText = ""

        if let next = textQueue.dequeue() {
            queueCount = textQueue.count
            state = .idle
            await speak(next)
        } else {
            queueCount = 0
            activeSessionID = nil
            state = .idle
            indicatorWindow.hide()
        }
    }

    private func provider(for kind: ReadAloudProvider) -> TextToSpeechProvider {
        switch kind {
        case .apple: return appleProvider
        case .elevenlabs: return elevenLabsProvider
        case .openai: return openAIProvider
        case .gemini: return geminiProvider
        }
    }

    private func configuredProviders() -> Set<ReadAloudProvider> {
        var providers = Set<ReadAloudProvider>()
        if APIKeyManager.shared.hasAPIKey(forProvider: "elevenlabs") { providers.insert(.elevenlabs) }
        if APIKeyManager.shared.hasAPIKey(forProvider: "openai") { providers.insert(.openai) }
        if APIKeyManager.shared.hasAPIKey(forProvider: "gemini") { providers.insert(.gemini) }
        if ReadAloudSettings.shared.fallbackProvider == .apple { providers.insert(.apple) }
        return providers
    }
}

private extension Float {
    /// Snap to N decimal places so repeated +/- 0.1 doesn't drift into 1.0999999.
    func rounded(toDecimalPlaces places: Int) -> Float {
        let factor = pow(10.0, Float(places))
        return (self * factor).rounded() / factor
    }
}
