import Foundation
import os
import AppKit

@MainActor
final class ModelPrewarmService: ObservableObject {
    private let transcriptionModelManager: TranscriptionModelManager
    private let whisperModelManager: WhisperModelManager
    private let serviceRegistry: TranscriptionServiceRegistry
    private let canPrewarm: @MainActor () -> Bool
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ModelPrewarm")
    private let prewarmEnabledKey = "PrewarmModelOnWake"
    private var prewarmTask: Task<Void, Never>?

    init(
        transcriptionModelManager: TranscriptionModelManager,
        whisperModelManager: WhisperModelManager,
        serviceRegistry: TranscriptionServiceRegistry,
        canPrewarm: @escaping @MainActor () -> Bool
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.whisperModelManager = whisperModelManager
        self.serviceRegistry = serviceRegistry
        self.canPrewarm = canPrewarm
        setupNotifications()
        schedulePrewarmOnAppLaunch()
    }

    // MARK: - Notification Setup

    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        // Trigger on wake from sleep
        center.addObserver(
            self,
            selector: #selector(schedulePrewarm),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        logger.notice("ModelPrewarmService initialized - listening for wake and app launch")
    }

    // MARK: - Trigger Handlers

    /// Trigger on app launch (cold start)
    private func schedulePrewarmOnAppLaunch() {
        logger.notice("App launched, scheduling prewarm")
        schedulePrewarmTask()
    }

    private func schedulePrewarmTask() {
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.performPrewarm()
        }
    }

    /// Trigger on wake from sleep or screen unlock
    @objc private func schedulePrewarm() {
        logger.notice("Mac activity detected (wake/unlock), scheduling prewarm")
        schedulePrewarmTask()
    }

    // MARK: - Core Prewarming Logic

    private func performPrewarm() async {
        guard shouldPrewarm() else { return }
        guard canPrewarm() else {
            logger.notice("App is busy, skipping prewarm")
            return
        }

        guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: transcriptionModelManager
        ) else {
            logger.notice("No model selected, skipping prewarm")
            return
        }
        let currentModel = transcriptionConfiguration.model

        logger.notice("Prewarming \(currentModel.displayName, privacy: .public)")
        let startTime = Date()

        do {
            switch currentModel.provider {
            case .whisper:
                guard let model = whisperModelManager.availableModels.first(where: { $0.name == currentModel.name }) else {
                    throw VoiceInkEngineError.modelLoadFailed
                }
                if whisperModelManager.loadedWhisperModel?.name != model.name || whisperModelManager.whisperContext == nil {
                    try await whisperModelManager.loadModel(model)
                }
            case .fluidAudio:
                guard let model = currentModel as? FluidAudioModel else {
                    throw VoiceInkEngineError.modelLoadFailed
                }
                try await serviceRegistry.fluidAudioTranscriptionService.loadModel(for: model)
            default:
                return
            }
            let duration = Date().timeIntervalSince(startTime)

            logger.notice("Prewarm completed in \(String(format: "%.2f", duration), privacy: .public)s")

        } catch {
            logger.error("❌ Prewarm failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Validation

    private func shouldPrewarm() -> Bool {
        // Check if user has enabled prewarming
        let isEnabled = UserDefaults.standard.bool(forKey: prewarmEnabledKey)
        guard isEnabled else {
            logger.notice("Prewarm disabled by user")
            return false
        }

        // Only prewarm local models (Parakeet and Whisper need ANE compilation)
        guard let model = ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: transcriptionModelManager
        )?.model else {
            return false
        }

        switch model.provider {
        case .whisper, .fluidAudio:
            return true
        default:
            logger.notice("Skipping prewarm - cloud models don't need it")
            return false
        }
    }

    deinit {
        prewarmTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        logger.notice("ModelPrewarmService deinitialized")
    }
}
