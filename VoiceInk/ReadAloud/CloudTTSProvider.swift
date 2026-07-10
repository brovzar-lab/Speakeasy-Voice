import Foundation
import AVFoundation
import OSLog

/// Errors surfaced by the cloud TTS providers so the manager can show useful messages.
enum CloudTTSError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case httpError(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return String(format: String(localized: "Missing %@ API key. Add it in Settings."), provider)
        case .invalidResponse:
            return String(localized: "The TTS provider returned an invalid response.")
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return String(format: String(localized: "TTS request failed (%d): %@"), code, body)
            }
            return String(format: String(localized: "TTS request failed (%d)."), code)
        case .decodingFailed:
            return String(localized: "Failed to decode TTS audio response.")
        }
    }
}

// MARK: - Shared audio playback backing

/// Minimal `AVAudioPlayer`-based playback helper used by both cloud providers.
///
/// Loads a full audio blob (mp3/aac) into memory, plays it via a single
/// `AVAudioPlayer`, and exposes async wait-until-finished semantics.
/// Also supports streaming PCM from ElevenLabs so playback can start before
/// the full response has arrived.
@MainActor
final class CloudTTSPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var progressTimer: Timer?
    private var streamingEngine: AVAudioEngine?
    private var streamingNode: AVAudioPlayerNode?
    /// Varispeed unit between the player node and mixer — required for reliable
    /// PCM rate control. `AVAudioPlayerNode.rate` is ignored on many macOS builds.
    private var streamingVarispeed: AVAudioUnitVarispeed?
    private var streamingFormat: AVAudioFormat?
    private var streamingTask: Task<Void, Never>?
    private var pendingStreamingBuffers = 0
    private var streamEnded = false
    private var currentPCMRate: Float = 1.0
    var onProgress: ((Double) -> Void)?

    var isPlaying: Bool {
        if let player, player.isPlaying { return true }
        if let streamingNode, streamingNode.isPlaying { return true }
        return false
    }
    var isPaused: Bool {
        if let player {
            return !player.isPlaying && player.currentTime > 0 && player.currentTime < player.duration
        }
        if let streamingNode, let engine = streamingEngine, engine.isRunning {
            return !streamingNode.isPlaying
        }
        return false
    }

    /// Play the given audio data, awaiting completion. Data is expected to be a
    /// standard container (mp3 / aac / wav) that `AVAudioPlayer` can decode.
    ///
    /// `initialRate` seeds `AVAudioPlayer.rate` for playback and enables live
    /// speed adjustment via `setRate(_:)` while the buffer is playing.
    func play(data: Data, volume: Float, initialRate: Float = 1.0) async {
        stop()

        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.volume = max(0.0, min(1.0, volume))
            // Enabling rate lets us change playback speed without a re-fetch.
            // The pitch shifts naturally with rate (like a tape), which usually
            // sounds fine for TTS at 0.5x–2.0x.
            p.enableRate = true
            p.rate = max(0.5, min(2.0, initialRate))
            p.prepareToPlay()
            player = p

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.continuation = cont
                p.play()
                self.startProgressTimer()
            }
        } catch {
            resolveContinuation()
        }
    }

    /// Stream 16-bit mono PCM and begin playback as soon as the first chunk arrives.
    func playStreamingPCM<S: AsyncSequence>(
        from stream: S,
        sampleRate: Double,
        volume: Float,
        initialRate: Float = 1.0
    ) async where S.Element == UInt8 {
        stop()

        guard setupPCMEngine(sampleRate: sampleRate, volume: volume, initialRate: initialRate) else {
            resolveContinuation()
            return
        }

        streamingNode?.play()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont

            self.streamingTask = Task { @MainActor in
                var pending = Data()
                let bytesPerFrame = 2
                // ~250ms of audio before we kick off playback.
                let startupThreshold = Int(sampleRate) * bytesPerFrame / 4
                var didStartPlayback = false

                do {
                    for try await byte in stream {
                        try Task.checkCancellation()
                        pending.append(byte)

                        let alignedCount = pending.count - (pending.count % bytesPerFrame)
                        guard alignedCount > 0 else { continue }

                        let shouldFlush = !didStartPlayback
                            ? alignedCount >= startupThreshold
                            : alignedCount >= startupThreshold / 2

                        if shouldFlush {
                            let chunk = pending.prefix(alignedCount)
                            pending.removeFirst(alignedCount)
                            self.scheduleStreamingPCMBuffer(Data(chunk))
                            didStartPlayback = true
                        }
                    }

                    if !pending.isEmpty {
                        let alignedCount = pending.count - (pending.count % bytesPerFrame)
                        if alignedCount > 0 {
                            self.scheduleStreamingPCMBuffer(Data(pending.prefix(alignedCount)))
                        }
                    }

                    self.streamEnded = true
                    if self.pendingStreamingBuffers == 0 {
                        self.finishStreamingPlayback()
                    }
                } catch {
                    self.finishStreamingPlayback()
                }
            }
        }
    }

    /// Play a complete 16-bit mono PCM buffer (used by Gemini batch responses).
    func play(pcmData: Data, sampleRate: Double, volume: Float, initialRate: Float = 1.0) async {
        stop()

        guard setupPCMEngine(sampleRate: sampleRate, volume: volume, initialRate: initialRate) else {
            resolveContinuation()
            return
        }

        let alignedCount = pcmData.count - (pcmData.count % 2)
        guard alignedCount > 0 else {
            resolveContinuation()
            return
        }

        scheduleStreamingPCMBuffer(Data(pcmData.prefix(alignedCount)))
        streamEnded = true
        streamingNode?.play()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            if self.pendingStreamingBuffers == 0 {
                self.finishStreamingPlayback()
            }
        }
    }

    func pause() {
        player?.pause()
        streamingNode?.pause()
    }

    func resume() {
        player?.play()
        streamingNode?.play()
    }

    /// Change playback speed of the currently-loaded audio in place.
    /// No-op when idle.
    func setRate(_ rate: Float) {
        let clamped = max(0.5, min(2.0, rate))
        currentPCMRate = clamped
        if let player {
            player.rate = clamped
        }
        // Varispeed is the reliable path for PCM (Gemini / ElevenLabs streaming).
        streamingVarispeed?.rate = clamped
        streamingNode?.rate = clamped
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        streamingTask?.cancel()
        streamingTask = nil
        streamingNode?.stop()
        streamingEngine?.stop()
        if let node = streamingNode {
            streamingEngine?.detach(node)
        }
        if let varispeed = streamingVarispeed {
            streamingEngine?.detach(varispeed)
        }
        streamingNode = nil
        streamingVarispeed = nil
        streamingEngine = nil
        streamingFormat = nil
        pendingStreamingBuffers = 0
        streamEnded = false
        currentPCMRate = 1.0
        player?.stop()
        player = nil
        resolveContinuation()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.resolveContinuation()
        }
    }

    /// Wire `AVAudioPlayerNode` → `AVAudioUnitVarispeed` → mixer so rate changes
    /// actually affect PCM playback (Gemini batch + streaming providers).
    @discardableResult
    private func setupPCMEngine(sampleRate: Double, volume: Float, initialRate: Float) -> Bool {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            return false
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let clampedRate = max(0.5, min(2.0, initialRate))
        varispeed.rate = clampedRate

        engine.attach(node)
        engine.attach(varispeed)
        engine.connect(node, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = max(0.0, min(1.0, volume))
        node.volume = max(0.0, min(1.0, volume))

        do {
            try engine.start()
        } catch {
            return false
        }

        streamingEngine = engine
        streamingNode = node
        streamingVarispeed = varispeed
        streamingFormat = format
        streamEnded = false
        pendingStreamingBuffers = 0
        currentPCMRate = clampedRate
        return true
    }

    private func scheduleStreamingPCMBuffer(_ data: Data) {
        guard let format = streamingFormat, let node = streamingNode else { return }

        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress,
                  let destination = buffer.int16ChannelData?.pointee else {
                return
            }
            memcpy(destination, source, data.count)
        }

        pendingStreamingBuffers += 1
        // Keep varispeed rate applied in case it was changed mid-stream.
        streamingVarispeed?.rate = currentPCMRate
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingStreamingBuffers = max(0, self.pendingStreamingBuffers - 1)
                if self.streamEnded, self.pendingStreamingBuffers == 0 {
                    self.finishStreamingPlayback()
                }
            }
        }
    }

    private func finishStreamingPlayback() {
        streamingTask = nil
        streamingNode?.stop()
        streamingEngine?.stop()
        if let node = streamingNode {
            streamingEngine?.detach(node)
        }
        if let varispeed = streamingVarispeed {
            streamingEngine?.detach(varispeed)
        }
        streamingNode = nil
        streamingVarispeed = nil
        streamingEngine = nil
        streamingFormat = nil
        resolveContinuation()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.onProgress?(min(1.0, player.currentTime / player.duration))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func resolveContinuation() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - ElevenLabs

/// Text-to-speech via the ElevenLabs REST API.
///
/// Prefers the streaming `/stream` endpoint with PCM output so playback can start
/// before the full response arrives. Falls back to batch mp3 if streaming fails.
@MainActor
final class ElevenLabsTTSProvider: TextToSpeechProvider {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.ElevenLabs")
    private let audioPlayer = CloudTTSPlayer()

    var onProgressUpdate: ((Double) -> Void)? {
        get { audioPlayer.onProgress }
        set { audioPlayer.onProgress = newValue }
    }

    var isSpeaking: Bool { audioPlayer.isPlaying }
    var isPaused: Bool { audioPlayer.isPaused }

    func speak(_ text: String, voice: VoiceConfiguration) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "elevenlabs"),
              !apiKey.isEmpty else {
            throw CloudTTSError.missingAPIKey("ElevenLabs")
        }

        let voiceId = voice.voiceIdentifier ?? "21m00Tcm4TlvDq8ikWAM"
        let modelId = ReadAloudSettings.shared.elevenLabsModelId

        let body: [String: Any] = [
            "text": trimmed,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        do {
            try await speakWithStreaming(
                voiceId: voiceId,
                modelId: modelId,
                bodyData: bodyData,
                apiKey: apiKey,
                trimmed: trimmed,
                voice: voice
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("ElevenLabs streaming failed, falling back to batch mp3: \(error.localizedDescription, privacy: .public)")
            try await speakWithBatchMP3(
                voiceId: voiceId,
                modelId: modelId,
                bodyData: bodyData,
                apiKey: apiKey,
                trimmed: trimmed,
                voice: voice
            )
        }
    }

    private func speakWithStreaming(
        voiceId: String,
        modelId: String,
        bodyData: Data,
        apiKey: String,
        trimmed: String,
        voice: VoiceConfiguration
    ) async throws {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_16000"),
            URLQueryItem(name: "optimize_streaming_latency", value: "4")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        request.httpBody = bodyData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8)
            throw CloudTTSError.httpError(http.statusCode, body)
        }

        try Task.checkCancellation()
        ReadAloudUsageTracker.shared.record(
            provider: "elevenlabs",
            model: modelId,
            voiceId: voiceId,
            characterCount: trimmed.count
        )

        await audioPlayer.playStreamingPCM(
            from: bytes,
            sampleRate: 16_000,
            volume: voice.volume,
            initialRate: voice.rate
        )
    }

    private func speakWithBatchMP3(
        voiceId: String,
        modelId: String,
        bodyData: Data,
        apiKey: String,
        trimmed: String,
        voice: VoiceConfiguration
    ) async throws {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPStatus(response: response, data: data)

        try Task.checkCancellation()
        ReadAloudUsageTracker.shared.record(
            provider: "elevenlabs",
            model: modelId,
            voiceId: voiceId,
            characterCount: trimmed.count
        )
        await audioPlayer.play(data: data, volume: voice.volume, initialRate: voice.rate)
    }

    func pause() { audioPlayer.pause() }
    func resume() { audioPlayer.resume() }
    func stop() { audioPlayer.stop() }
    func setLiveRate(_ rate: Float) { audioPlayer.setRate(rate) }

    private static func checkHTTPStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw CloudTTSError.httpError(http.statusCode, body)
        }
    }
}

// MARK: - OpenAI

/// Text-to-speech via OpenAI's `/v1/audio/speech` endpoint.
///
/// Requests mp3 output for broad AVAudioPlayer compatibility. Supports the
/// `tts-1` (fast) and `tts-1-hd` (higher fidelity) models.
@MainActor
final class OpenAITTSProvider: TextToSpeechProvider {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.OpenAI")
    private let audioPlayer = CloudTTSPlayer()

    var onProgressUpdate: ((Double) -> Void)? {
        get { audioPlayer.onProgress }
        set { audioPlayer.onProgress = newValue }
    }

    var isSpeaking: Bool { audioPlayer.isPlaying }
    var isPaused: Bool { audioPlayer.isPaused }

    func speak(_ text: String, voice: VoiceConfiguration) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "openai"),
              !apiKey.isEmpty else {
            throw CloudTTSError.missingAPIKey("OpenAI")
        }

        let model = ReadAloudSettings.shared.openAIModel
        let voiceName = voice.voiceIdentifier ?? "nova"

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "input": trimmed,
            "voice": voiceName,
            "response_format": "mp3",
            "speed": max(0.25, min(4.0, Double(voice.rate)))
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPStatus(response: response, data: data)

        try Task.checkCancellation()
        ReadAloudUsageTracker.shared.record(
            provider: "openai",
            model: model,
            voiceId: voiceName,
            characterCount: trimmed.count
        )
        // OpenAI honors `speed` at generation time, so we can start at 1.0×
        // and layer any further live adjustment on top via player rate.
        await audioPlayer.play(data: data, volume: voice.volume, initialRate: 1.0)
    }

    func pause() { audioPlayer.pause() }
    func resume() { audioPlayer.resume() }
    func stop() { audioPlayer.stop() }
    func setLiveRate(_ rate: Float) { audioPlayer.setRate(rate) }

    private static func checkHTTPStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw CloudTTSError.httpError(http.statusCode, body)
        }
    }
}

// MARK: - Gemini

/// Text-to-speech via the Gemini `generateContent` / `streamGenerateContent` APIs.
///
/// Returns 24 kHz 16-bit mono PCM. Gemini 3.1 Flash supports streaming so playback
/// can start before the full response arrives; 2.5 Flash uses batch generateContent.
@MainActor
final class GeminiTTSProvider: TextToSpeechProvider {
    static let pcmSampleRate: Double = 24_000

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.Gemini")
    private let audioPlayer = CloudTTSPlayer()

    var onProgressUpdate: ((Double) -> Void)? {
        get { audioPlayer.onProgress }
        set { audioPlayer.onProgress = newValue }
    }

    var isSpeaking: Bool { audioPlayer.isPlaying }
    var isPaused: Bool { audioPlayer.isPaused }

    func speak(_ text: String, voice: VoiceConfiguration) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "gemini"),
              !apiKey.isEmpty else {
            throw CloudTTSError.missingAPIKey("Gemini")
        }

        let model = ReadAloudSettings.shared.geminiModel
        let voiceName = voice.voiceIdentifier ?? "Kore"
        let bodyData = try Self.makeRequestBody(text: trimmed, voiceName: voiceName)

        let settings = ReadAloudSettings.shared
        if settings.geminiSupportsStreaming {
            do {
                try await speakWithStreaming(
                    model: model,
                    bodyData: bodyData,
                    apiKey: apiKey,
                    trimmed: trimmed,
                    voiceName: voiceName,
                    voice: voice
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Gemini streaming failed, falling back to batch: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await speakWithBatch(
            model: model,
            bodyData: bodyData,
            apiKey: apiKey,
            trimmed: trimmed,
            voiceName: voiceName,
            voice: voice
        )
    }

    func pause() { audioPlayer.pause() }
    func resume() { audioPlayer.resume() }
    func stop() { audioPlayer.stop() }
    func setLiveRate(_ rate: Float) { audioPlayer.setRate(rate) }

    private static func makeRequestBody(text: String, voiceName: String) throws -> Data {
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": text]]]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceName
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func speakWithBatch(
        model: String,
        bodyData: Data,
        apiKey: String,
        trimmed: String,
        voiceName: String,
        voice: VoiceConfiguration
    ) async throws {
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTPStatus(response: response, data: data)

        try Task.checkCancellation()
        guard let pcm = Self.extractPCM(from: data) else {
            throw CloudTTSError.decodingFailed
        }

        ReadAloudUsageTracker.shared.record(
            provider: "gemini",
            model: model,
            voiceId: voiceName,
            characterCount: trimmed.count
        )

        await audioPlayer.play(
            pcmData: pcm,
            sampleRate: Self.pcmSampleRate,
            volume: voice.volume,
            initialRate: voice.rate
        )
    }

    private func speakWithStreaming(
        model: String,
        bodyData: Data,
        apiKey: String,
        trimmed: String,
        voiceName: String,
        voice: VoiceConfiguration
    ) async throws {
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = bodyData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8)
            throw CloudTTSError.httpError(http.statusCode, body)
        }

        try Task.checkCancellation()
        ReadAloudUsageTracker.shared.record(
            provider: "gemini",
            model: model,
            voiceId: voiceName,
            characterCount: trimmed.count
        )

        let pcmStream = GeminiPCMStreamDecoder(bytes: bytes)
        await audioPlayer.playStreamingPCM(
            from: pcmStream,
            sampleRate: Self.pcmSampleRate,
            volume: voice.volume,
            initialRate: voice.rate
        )
    }

    private static func extractPCM(from data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }

        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let encoded = inlineData["data"] as? String,
               let pcm = Data(base64Encoded: encoded) {
                return pcm
            }
        }
        return nil
    }

    private static func checkHTTPStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw CloudTTSError.httpError(http.statusCode, body)
        }
    }
}

/// Decodes Gemini `streamGenerateContent` JSON chunks into a raw PCM byte stream.
private struct GeminiPCMStreamDecoder: AsyncSequence {
    typealias Element = UInt8

    private let bytes: URLSession.AsyncBytes
    private let inlineDataRegex: NSRegularExpression

    init(bytes: URLSession.AsyncBytes) {
        self.bytes = bytes
        self.inlineDataRegex = try! NSRegularExpression(
            pattern: #""inlineData"\s*:\s*\{\s*"(?:mimeType|mime_type)"\s*:\s*"[^"]*"\s*,\s*"data"\s*:\s*"([A-Za-z0-9+/=]+)""#
        )
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        private let inlineDataRegex: NSRegularExpression
        private var textBuffer = ""
        private var emittedHashes = Set<Int>()
        private var pendingPCM = Data()
        private var pendingIndex = 0
        private var finished = false
        private var byteIterator: URLSession.AsyncBytes.AsyncIterator

        init(bytes: URLSession.AsyncBytes, inlineDataRegex: NSRegularExpression) {
            self.inlineDataRegex = inlineDataRegex
            self.byteIterator = bytes.makeAsyncIterator()
        }

        mutating func next() async throws -> UInt8? {
            while true {
                if pendingIndex < pendingPCM.count {
                    let byte = pendingPCM[pendingIndex]
                    pendingIndex += 1
                    return byte
                }

                pendingPCM.removeAll(keepingCapacity: true)
                pendingIndex = 0

                if finished {
                    return nil
                }

                var didRead = false
                while let byte = try await byteIterator.next() {
                    didRead = true
                    textBuffer.append(Character(UnicodeScalar(byte)))
                    extractNewPCMChunks()
                    if !pendingPCM.isEmpty {
                        break
                    }
                }

                if !didRead {
                    finished = true
                    return nil
                }
            }
        }

        private mutating func extractNewPCMChunks() {
            let nsRange = NSRange(textBuffer.startIndex..<textBuffer.endIndex, in: textBuffer)
            let matches = inlineDataRegex.matches(in: textBuffer, range: nsRange)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let dataRange = Range(match.range(at: 1), in: textBuffer) else {
                    continue
                }
                let encoded = String(textBuffer[dataRange])
                let hash = encoded.hashValue
                guard !emittedHashes.contains(hash),
                      let chunk = Data(base64Encoded: encoded) else {
                    continue
                }
                emittedHashes.insert(hash)
                pendingPCM.append(chunk)
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes, inlineDataRegex: inlineDataRegex)
    }
}
