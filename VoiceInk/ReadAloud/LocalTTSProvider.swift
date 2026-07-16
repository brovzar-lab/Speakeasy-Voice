import Foundation
import Combine
import MLXAudioTTS

enum LocalTTSError: LocalizedError {
    case unexpectedModel
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedModel:
            return "The Local HD voice model could not be loaded. Try downloading it again."
        case .generationFailed(let message):
            return "Local HD could not generate this selection: \(message)"
        }
    }
}

enum LocalTTSModelState: Equatable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)
}

/// Loads Kokoro once and keeps it warm between reads. Model loading and MLX
/// work run outside MainActor so the settings window and floating player stay
/// responsive during the first download and every synthesis.
@MainActor
final class LocalTTSModelManager: ObservableObject {
    static let shared = LocalTTSModelManager()
    static let modelRepository = "mlx-community/Kokoro-82M-bf16"

    private static let installedKey = "readAloud.localKokoroInstalled_v1"

    @Published private(set) var state: LocalTTSModelState

    private var loadedModel: KokoroModel?
    private var loadTask: Task<KokoroModel, Error>?

    var isInstalled: Bool {
        if case .ready = state { return true }
        return UserDefaults.standard.bool(forKey: Self.installedKey)
    }

    private init() {
        state = .notDownloaded
    }

    func prepare() async throws -> KokoroModel {
        if let loadedModel {
            state = .ready
            return loadedModel
        }
        if let loadTask {
            return try await loadTask.value
        }

        state = .downloading
        let task = Task.detached(priority: .userInitiated) { () throws -> KokoroModel in
            let loaded = try await TTS.loadModel(modelRepo: Self.modelRepository)
            guard let kokoro = loaded as? KokoroModel else {
                throw LocalTTSError.unexpectedModel
            }

            // The Spanish lexicon is large enough to be noticeable on its first
            // use. Prepare both supported languages now so the first sentence
            // starts quickly later.
            if let processor = kokoro.textProcessor as? KokoroMultilingualProcessor {
                try await processor.prepare(for: "en-us")
                try await processor.prepare(for: "es")
            }
            return kokoro
        }
        loadTask = task

        do {
            let model = try await task.value
            loadedModel = model
            loadTask = nil
            state = .ready
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            return model
        } catch {
            loadTask = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadedModel = nil
        state = .notDownloaded
    }
}

private final class LocalTTSGenerationErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func set(_ error: Error) {
        lock.withLock { storedError = error }
    }

    func get() -> Error? {
        lock.withLock { storedError }
    }
}

/// Free, on-device Kokoro speech. Text is planned into short sections, while
/// samples from each section are fed into one continuous audio-engine session.
@MainActor
final class LocalKokoroTTSProvider: TextToSpeechProvider {
    private let modelManager: LocalTTSModelManager
    private let audioPlayer = CloudTTSPlayer()
    private var generationTask: Task<Void, Never>?

    init(modelManager: LocalTTSModelManager) {
        self.modelManager = modelManager
    }

    var onProgressUpdate: ((Double) -> Void)? {
        didSet { audioPlayer.onProgress = onProgressUpdate }
    }
    var onBufferingUpdate: ((Bool) -> Void)? {
        didSet { audioPlayer.onBufferingChanged = onBufferingUpdate }
    }

    var isSpeaking: Bool { audioPlayer.isPlaying }
    var isPaused: Bool { audioPlayer.isPaused }

    func speak(_ text: String, voice: VoiceConfiguration) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let model = try await modelManager.prepare()
        let voiceID = voice.voiceIdentifier ?? "am_michael"
        let language = voice.languageCode ?? LocalKokoroVoices.languageCode(for: voiceID)
        let segments = ReadAloudSegmentPlanner.plan(text: trimmed).segments
        let errorBox = LocalTTSGenerationErrorBox()

        let (stream, continuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(3)
        )

        let task = Task.detached(priority: .userInitiated) { [model] in
            do {
                for segment in segments {
                    try Task.checkCancellation()
                    let generated = model.generateSamplesStream(
                        text: segment.text,
                        voice: voiceID,
                        refAudio: nil,
                        refText: nil,
                        language: language,
                        streamingInterval: 0.5
                    )
                    for try await samples in generated {
                        try Task.checkCancellation()
                        try await Self.yieldWithBackpressure(samples, to: continuation)
                    }
                }
            } catch {
                errorBox.set(error)
            }
            continuation.finish()
        }
        generationTask = task
        continuation.onTermination = { _ in task.cancel() }

        await audioPlayer.playStreamingFloat32(
            from: stream,
            sampleRate: Double(model.sampleRate),
            volume: voice.volume,
            initialRate: voice.rate
        )
        await task.value
        generationTask = nil

        if let error = errorBox.get() {
            if error is CancellationError { throw CancellationError() }
            throw LocalTTSError.generationFailed(error.localizedDescription)
        }

        ReadAloudUsageTracker.shared.record(
            provider: "local",
            model: LocalTTSModelManager.modelRepository,
            voiceId: voiceID,
            characterCount: trimmed.count
        )
        onProgressUpdate?(1)
    }

    func pause() { audioPlayer.pause() }
    func resume() { audioPlayer.resume() }
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        audioPlayer.stop()
    }
    func setLiveRate(_ rate: Float) { audioPlayer.setRate(rate) }
    func seek(by seconds: TimeInterval) -> Bool { false }

    private nonisolated static func yieldWithBackpressure(
        _ samples: [Float],
        to continuation: AsyncStream<[Float]>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(samples) {
            case .enqueued:
                return
            case .dropped:
                try await Task.sleep(for: .milliseconds(20))
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}
