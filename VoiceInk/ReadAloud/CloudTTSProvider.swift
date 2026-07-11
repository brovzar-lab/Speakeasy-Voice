import Foundation
import AVFoundation
import OSLog

/// Errors surfaced by the cloud TTS providers so the manager can show useful messages.
enum CloudTTSError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case httpError(Int, String?)
    case decodingFailed
    case emptyAudioStream
    case streamEndedEarly

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
        case .emptyAudioStream:
            return String(localized: "The TTS provider returned no audio.")
        case .streamEndedEarly:
            return String(localized: "The TTS provider ended the audio early.")
        }
    }
}

struct GeminiSSEEvent: Equatable, Sendable {
    let pcm: Data?
    let finishReason: String?
}

enum GeminiSSEDecodingError: Error {
    case malformedEvent
}

enum GeminiStreamFailurePolicy {
    static func resolve(bytesPlayed: Int, underlying: CloudTTSError) -> CloudTTSError {
        if bytesPlayed > 0 {
            return .streamEndedEarly
        }
        if case .streamEndedEarly = underlying {
            return .emptyAudioStream
        }
        return underlying
    }
}

/// Pure SSE event decoder kept outside the MainActor provider so JSON/base64
/// work can be tested and performed on a background executor.
enum GeminiSSEEventDecoder {
    static func decode(_ line: Data) throws -> GeminiSSEEvent? {
        var payload = line
        while let first = payload.first, first == 0x20 || first == 0x09 || first == 0x0D {
            payload.removeFirst()
        }
        while let last = payload.last, last == 0x20 || last == 0x09 || last == 0x0D {
            payload.removeLast()
        }

        // SSE permits blank separators, comments, and metadata fields alongside
        // data events. They carry no Gemini JSON payload and should be ignored.
        if payload.isEmpty
            || payload.first == 0x3A
            || payload.starts(with: Data("event:".utf8))
            || payload.starts(with: Data("id:".utf8))
            || payload.starts(with: Data("retry:".utf8)) {
            return nil
        }

        if payload.starts(with: Data("data:".utf8)) {
            payload.removeFirst(5)
            if payload.first == 0x20 { payload.removeFirst() }
        }

        guard !payload.isEmpty, payload != Data("[DONE]".utf8) else { return nil }
        guard payload.first == 0x7B,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw GeminiSSEDecodingError.malformedEvent
        }

        let finishReason = first["finishReason"] as? String ?? first["finish_reason"] as? String
        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var combined = Data()

        for part in parts {
            let inlineData = part["inlineData"] as? [String: Any]
                ?? part["inline_data"] as? [String: Any]
            guard let encoded = inlineData?["data"] as? String,
                  let pcm = Data(base64Encoded: encoded) else {
                continue
            }
            combined.append(pcm)
        }

        return GeminiSSEEvent(
            pcm: combined.isEmpty ? nil : combined,
            finishReason: finishReason
        )
    }
}

private final class GeminiStreamMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: Date
    private var byteCount = 0
    private var storedError: CloudTTSError?
    private var firstPCMSeconds: TimeInterval?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func record(bytes: Int) {
        lock.lock()
        if firstPCMSeconds == nil {
            firstPCMSeconds = Date().timeIntervalSince(startedAt)
        }
        byteCount += bytes
        lock.unlock()
    }

    func fail(_ error: CloudTTSError) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var result: (bytes: Int, error: CloudTTSError?, firstPCMSeconds: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        return (byteCount, storedError, firstPCMSeconds)
    }
}

struct PCMStreamSegment: @unchecked Sendable {
    let stream: AsyncStream<Data>
    let cancel: @Sendable () -> Void
    let validate: @Sendable () throws -> Void

    static func wrapping(_ stream: AsyncStream<Data>) -> PCMStreamSegment {
        PCMStreamSegment(stream: stream, cancel: {}, validate: {})
    }
}

private final class PCMStreamTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (@Sendable () -> Void)?
    private var isCancelled = false

    func install(_ cancelAction: @escaping @Sendable () -> Void) {
        lock.lock()
        self.cancelAction = cancelAction
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { cancelAction() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let action = cancelAction
        lock.unlock()
        action?()
    }
}

private final class PCMStreamPrefetchSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var taskCancel: (@Sendable () -> Void)?
    private var segment: PCMStreamSegment?
    private var isCancelled = false

    func installTask(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        taskCancel = cancel
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { cancel() }
    }

    func installSegment(_ segment: PCMStreamSegment) {
        lock.lock()
        self.segment = segment
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { segment.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let cancelTask = taskCancel
        let cancelSegment = segment?.cancel
        lock.unlock()
        cancelTask?()
        cancelSegment?()
    }
}

private final class PCMStreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PCMStreamSegment?
    private var prefetched: PCMStreamPrefetchSlot?

    func setCurrent(_ segment: PCMStreamSegment?) {
        lock.lock()
        current = segment
        lock.unlock()
    }

    func setPrefetched(_ slot: PCMStreamPrefetchSlot?) {
        lock.lock()
        prefetched = slot
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let current = current
        let prefetched = prefetched
        lock.unlock()
        current?.cancel()
        prefetched?.cancel()
    }
}

/// Joins multiple PCM-producing requests into one ordered stream. It keeps one
/// bounded text segment ahead so provider setup cannot create an audible gap,
/// while explicit cancellation handles stop both current and prefetched work.
enum PCMStreamConcatenator {
    @MainActor
    static func concatenate(_ streams: [AsyncStream<Data>]) -> AsyncStream<Data> {
        concatenate(count: streams.count) { index in
            PCMStreamSegment.wrapping(streams[index])
        }
    }

    @MainActor
    static func concatenate(
        count: Int,
        segmentAt: @escaping @MainActor (Int) async throws -> PCMStreamSegment,
        onChunk: @escaping @MainActor (Data) -> Void = { _ in },
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> AsyncStream<Data> {
        let lifecycle = PCMStreamLifecycle()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                func prefetch(_ index: Int) -> (
                    slot: PCMStreamPrefetchSlot,
                    task: Task<PCMStreamSegment, Error>
                ) {
                    let slot = PCMStreamPrefetchSlot()
                    let task = Task { @MainActor in
                        let segment = try await segmentAt(index)
                        slot.installSegment(segment)
                        return segment
                    }
                    slot.installTask { task.cancel() }
                    lifecycle.setPrefetched(slot)
                    return (slot, task)
                }

                var pending = count > 0 ? prefetch(0) : nil
                do {
                    for index in 0..<count {
                        try Task.checkCancellation()
                        guard let currentPending = pending else { break }
                        let segment = try await withTaskCancellationHandler {
                            try await currentPending.task.value
                        } onCancel: {
                            currentPending.slot.cancel()
                        }

                        lifecycle.setCurrent(segment)
                        if index + 1 < count {
                            pending = prefetch(index + 1)
                        } else {
                            pending = nil
                            lifecycle.setPrefetched(nil)
                        }

                        for await chunk in segment.stream {
                            try Task.checkCancellation()
                            if !chunk.isEmpty {
                                onChunk(chunk)
                                continuation.yield(chunk)
                            }
                        }
                        try segment.validate()
                        segment.cancel()
                        lifecycle.setCurrent(nil)
                    }
                } catch {
                    onError(error)
                }
                lifecycle.cancelAll()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                lifecycle.cancelAll()
                task.cancel()
            }
        }
    }
}

/// Owns the user-visible invariant that any number of cloud PCM segments are
/// consumed by exactly one playback session.
enum PCMContinuousPlaybackCoordinator {
    @MainActor
    static func play(
        streams: [AsyncStream<Data>],
        playback: @escaping @MainActor (AsyncStream<Data>) async -> Void
    ) async {
        await playback(PCMStreamConcatenator.concatenate(streams))
    }

    @MainActor
    static func play(
        count: Int,
        segmentAt: @escaping @MainActor (Int) async throws -> PCMStreamSegment,
        onChunk: @escaping @MainActor (Data) -> Void,
        onError: @escaping @MainActor (Error) -> Void,
        playback: @escaping @MainActor (AsyncStream<Data>) async -> Void
    ) async {
        let stream = PCMStreamConcatenator.concatenate(
            count: count,
            segmentAt: segmentAt,
            onChunk: onChunk,
            onError: onError
        )
        await playback(stream)
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
    /// Guards against double-resume of the playback continuation (crashes otherwise).
    private var didResolveContinuation = false
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
        didResolveContinuation = false

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
    ///
    /// Expects **Data chunks** (not individual bytes). Network/decode work runs off
    /// the main actor; only buffer scheduling hops to MainActor. Byte-at-a-time
    /// MainActor streaming previously crashed SwiftUI on macOS 26.
    func playStreamingPCM(
        from stream: AsyncStream<Data>,
        sampleRate: Double,
        volume: Float,
        initialRate: Float = 1.0
    ) async {
        stop()
        didResolveContinuation = false

        guard setupPCMEngine(sampleRate: sampleRate, volume: volume, initialRate: initialRate) else {
            resolveContinuation()
            return
        }

        streamingNode?.play()

        let bytesPerFrame = 2
        // ~250ms of audio before we kick off playback.
        let startupThreshold = Int(sampleRate) * bytesPerFrame / 4

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont

            // The network decoder produces coarse Data chunks off MainActor.
            // Buffer scheduling stays explicitly on MainActor because AVAudioEngine
            // is actor-bound. This avoids detached tasks retaining actor objects.
            self.streamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var pending = Data()
                var didStartPlayback = false

                do {
                    for await chunk in stream {
                        try Task.checkCancellation()
                        guard !chunk.isEmpty else { continue }
                        pending.append(chunk)

                        let alignedCount = pending.count - (pending.count % bytesPerFrame)
                        guard alignedCount > 0 else { continue }

                        let shouldFlush = !didStartPlayback
                            ? alignedCount >= startupThreshold
                            : alignedCount >= startupThreshold / 2

                        if shouldFlush {
                            let toPlay = Data(pending.prefix(alignedCount))
                            pending.removeFirst(alignedCount)
                            didStartPlayback = true
                            self.scheduleStreamingPCMBuffer(toPlay)
                        }
                    }

                    if !pending.isEmpty {
                        let alignedCount = pending.count - (pending.count % bytesPerFrame)
                        if alignedCount > 0 {
                            let toPlay = Data(pending.prefix(alignedCount))
                            self.scheduleStreamingPCMBuffer(toPlay)
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

    /// Play a complete 16-bit mono PCM buffer.
    ///
    /// Wraps the PCM in a WAV container and plays via `AVAudioPlayer` — same
    /// path as OpenAI/ElevenLabs mp3 — so rate control works and we avoid
    /// AVAudioEngine teardown races that were crashing the floating indicator.
    func play(pcmData: Data, sampleRate: Double, volume: Float, initialRate: Float = 1.0) async {
        let wav = Self.makeWAV(pcmData: pcmData, sampleRate: Int(sampleRate))
        await play(data: wav, volume: volume, initialRate: initialRate)
    }

    /// Build a minimal WAV header around raw 16-bit mono PCM.
    private static func makeWAV(pcmData: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        var wav = Data()
        wav.reserveCapacity(44 + pcmData.count)

        func appendASCII(_ s: String) { wav.append(contentsOf: s.utf8) }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendASCII("data")
        appendUInt32(dataSize)
        wav.append(pcmData)
        return wav
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
        // Varispeed is the reliable path for streaming PCM (ElevenLabs / Gemini 3.1).
        streamingVarispeed?.rate = clamped
        streamingNode?.rate = clamped
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        streamingTask?.cancel()
        streamingTask = nil

        // Stop playback first; do not detach nodes while callbacks may still fire.
        streamingNode?.stop()
        if let engine = streamingEngine, engine.isRunning {
            engine.stop()
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
    /// actually affect streaming PCM playback.
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
        if let engine = streamingEngine, engine.isRunning {
            engine.stop()
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
        guard !didResolveContinuation else { return }
        didResolveContinuation = true
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

        let pcmStream = Self.chunkAsyncBytes(bytes, chunkSize: 8_192)
        await audioPlayer.playStreamingPCM(
            from: pcmStream,
            sampleRate: 16_000,
            volume: voice.volume,
            initialRate: voice.rate
        )
    }

    /// Fold `URLSession.AsyncBytes` into ~8KB `Data` chunks so playback never
    /// hops to MainActor once per byte.
    private static func chunkAsyncBytes(_ bytes: URLSession.AsyncBytes, chunkSize: Int) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(chunkSize)
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer = Data()
                            buffer.reserveCapacity(chunkSize)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
/// Returns 24 kHz 16-bit mono PCM. Gemini 3.1 Flash streams via SSE (PCM chunks
/// decoded off the main actor). Older 2.5 models use batch `generateContent`.
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
        let settings = ReadAloudSettings.shared
        let chunks: [String]
        if trimmed.count > SentenceChunker.maxChunkChars,
           let split = SentenceChunker.chunkIfNeeded(trimmed) {
            chunks = split
        } else {
            chunks = [trimmed]
        }

        if settings.geminiSupportsStreaming {
            do {
                let bodies = try chunks.map { try Self.makeRequestBody(text: $0, voiceName: voiceName) }
                try await speakWithStreaming(
                    model: model,
                    bodyDatas: bodies,
                    apiKey: apiKey,
                    voice: voice
                )
                ReadAloudUsageTracker.shared.record(
                    provider: "gemini",
                    model: model,
                    voiceId: voiceName,
                    characterCount: trimmed.count
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch CloudTTSError.streamEndedEarly {
                // Audio may already have played. Replaying the selection via
                // batch would duplicate speech, so surface a clear error.
                throw CloudTTSError.streamEndedEarly
            } catch {
                logger.warning("Gemini streaming failed before playback, falling back to continuous batch playback: \(error.localizedDescription, privacy: .public)")
            }
        }

        let bodies = try chunks.map { try Self.makeRequestBody(text: $0, voiceName: voiceName) }
        try await speakWithBatch(
            model: model,
            bodyDatas: bodies,
            apiKey: apiKey,
            voice: voice
        )

        ReadAloudUsageTracker.shared.record(
            provider: "gemini",
            model: model,
            voiceId: voiceName,
            characterCount: trimmed.count
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
        bodyDatas: [Data],
        apiKey: String,
        voice: VoiceConfiguration
    ) async throws {
        var combinedPCM = Data()

        for bodyData in bodyDatas {
            try Task.checkCancellation()
            combinedPCM.append(try await batchPCM(
                model: model,
                bodyData: bodyData,
                apiKey: apiKey
            ))
        }

        guard !combinedPCM.isEmpty else { throw CloudTTSError.emptyAudioStream }
        await audioPlayer.play(
            pcmData: combinedPCM,
            sampleRate: Self.pcmSampleRate,
            volume: voice.volume,
            initialRate: voice.rate
        )
        try Task.checkCancellation()
    }

    private func batchPCM(
        model: String,
        bodyData: Data,
        apiKey: String
    ) async throws -> Data {
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
        let event: GeminiSSEEvent?
        do {
            event = try GeminiSSEEventDecoder.decode(data)
        } catch {
            throw CloudTTSError.decodingFailed
        }
        guard let pcm = event?.pcm else {
            throw CloudTTSError.decodingFailed
        }

        return pcm
    }

    private func speakWithStreaming(
        model: String,
        bodyDatas: [Data],
        apiKey: String,
        voice: VoiceConfiguration
    ) async throws {
        let playbackStart = Date()
        let aggregateMonitor = GeminiStreamMonitor(startedAt: playbackStart)

        await PCMContinuousPlaybackCoordinator.play(
            count: bodyDatas.count,
            segmentAt: { [weak self] index in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()

                if aggregateMonitor.result.error != nil {
                    return PCMStreamSegment.wrapping(AsyncStream { $0.finish() })
                }

                let (chunkSegment, chunkMonitor) = try await self.streamingPCMStream(
                    model: model,
                    bodyData: bodyDatas[index],
                    apiKey: apiKey
                )

                return PCMStreamSegment(
                    stream: chunkSegment.stream,
                    cancel: chunkSegment.cancel,
                    validate: {
                        let result = chunkMonitor.result
                        if let error = result.error {
                            throw GeminiStreamFailurePolicy.resolve(
                                bytesPlayed: aggregateMonitor.result.bytes,
                                underlying: error
                            )
                        } else if result.bytes == 0 {
                            throw GeminiStreamFailurePolicy.resolve(
                                bytesPlayed: aggregateMonitor.result.bytes,
                                underlying: .emptyAudioStream
                            )
                        }
                    }
                )
            },
            onChunk: { pcm in
                aggregateMonitor.record(bytes: pcm.count)
            },
            onError: { error in
                aggregateMonitor.fail(GeminiStreamFailurePolicy.resolve(
                    bytesPlayed: aggregateMonitor.result.bytes,
                    underlying: (error as? CloudTTSError) ?? .decodingFailed
                ))
            },
            playback: { [weak self] combinedStream in
                guard let self else { return }
                await self.audioPlayer.playStreamingPCM(
                    from: combinedStream,
                    sampleRate: Self.pcmSampleRate,
                    volume: voice.volume,
                    initialRate: voice.rate
                )
            }
        )
        try Task.checkCancellation()

        let result = aggregateMonitor.result
        if let firstPCMSeconds = result.firstPCMSeconds {
            logger.notice("[LATENCY] Gemini first-pcm duration=\(firstPCMSeconds, format: .fixed(precision: 3), privacy: .public)s bytes=\(result.bytes, privacy: .public)")
        }
        if let error = result.error { throw error }
        guard result.bytes > 0 else { throw CloudTTSError.emptyAudioStream }
    }

    private func streamingPCMStream(
        model: String,
        bodyData: Data,
        apiKey: String
    ) async throws -> (PCMStreamSegment, GeminiStreamMonitor) {
        let requestStart = Date()
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
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
        logger.notice("[LATENCY] Gemini response-headers duration=\(Date().timeIntervalSince(requestStart), format: .fixed(precision: 3), privacy: .public)s")

        try Task.checkCancellation()
        return Self.decodeGeminiSSEToPCMChunks(bytes, startedAt: requestStart)
    }

    /// Decode Gemini SSE into PCM `Data` chunks on a background task.
    private static func decodeGeminiSSEToPCMChunks(
        _ bytes: URLSession.AsyncBytes,
        startedAt: Date
    ) -> (PCMStreamSegment, GeminiStreamMonitor) {
        let monitor = GeminiStreamMonitor(startedAt: startedAt)
        let taskHandle = PCMStreamTaskHandle()
        let stream = AsyncStream<Data> { continuation in
            let task = Task.detached {
                var lineBuffer = Data()
                var networkChunk = Data()
                networkChunk.reserveCapacity(8_192)

                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        networkChunk.append(byte)
                        guard networkChunk.count >= 8_192 || byte == 0x0A else { continue }

                        lineBuffer.append(networkChunk)
                        networkChunk.removeAll(keepingCapacity: true)

                        while let newline = lineBuffer.firstIndex(of: 0x0A) {
                            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
                            let nextStart = lineBuffer.index(after: newline)
                            lineBuffer.removeSubrange(lineBuffer.startIndex..<nextStart)
                            try processGeminiSSELine(line, continuation: continuation, monitor: monitor)
                        }
                    }

                    if !networkChunk.isEmpty {
                        lineBuffer.append(networkChunk)
                    }
                    if !lineBuffer.isEmpty {
                        try processGeminiSSELine(lineBuffer, continuation: continuation, monitor: monitor)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    monitor.fail(.decodingFailed)
                    continuation.finish()
                }
            }
            taskHandle.install { task.cancel() }
            continuation.onTermination = { _ in taskHandle.cancel() }
        }
        return (
            PCMStreamSegment(
                stream: stream,
                cancel: { taskHandle.cancel() },
                validate: {}
            ),
            monitor
        )
    }

    nonisolated private static func processGeminiSSELine(
        _ line: Data,
        continuation: AsyncStream<Data>.Continuation,
        monitor: GeminiStreamMonitor
    ) throws {
        guard let event = try GeminiSSEEventDecoder.decode(line) else { return }
        if let pcm = event.pcm, !pcm.isEmpty {
            monitor.record(bytes: pcm.count)
            continuation.yield(pcm)
        }
        if event.finishReason == "OTHER" {
            monitor.fail(.streamEndedEarly)
        }
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
