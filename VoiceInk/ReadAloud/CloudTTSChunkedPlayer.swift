import Foundation
import AVFoundation
import OSLog

/// Compatibility wrapper retained for older tests and call sites. New cloud
/// playback uses `ReadAloudSegmentPlanner` directly.
enum SentenceChunker {
    /// Below this length we don't chunk at all — the overhead (multiple HTTP
    /// requests, delegate wiring) outweighs the latency benefit.
    static let singleRequestThreshold = ReadAloudSegmentPlanner.singleRequestThreshold

    /// Target chunk size in characters. Slightly larger than a typical
    /// sentence, so short sentences stay together and long ones split.
    static let targetChunkChars = ReadAloudSegmentPlanner.targetCharacters

    /// Never exceed this even if we can't find a good boundary.
    static let maxChunkChars = ReadAloudSegmentPlanner.maximumCharacters

    /// Returns `nil` if the text is short enough for a single request.
    /// Returns an array of chunk strings otherwise.
    static func chunkIfNeeded(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > singleRequestThreshold else { return nil }
        let chunks = ReadAloudSegmentPlanner.plan(text: trimmed).segments.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return chunks.count > 1 ? chunks : nil
    }

}

/// Plays a series of mp3 chunks (from parallel HTTP requests) as a single
/// gapless audio stream. Chunks may arrive out of order but are played in the
/// order they were declared.
///
/// Design goals:
/// - Playback starts as soon as chunk 0 arrives, even if chunks 1..N are still
///   downloading. That's the whole reason chunking is worth the complexity.
/// - Live rate change (tortoise/hare) applies to the currently-playing chunk
///   AND all future ones.
/// - Stop / pause / resume affect the whole queue.
@MainActor
final class CloudTTSChunkedPlayer: NSObject, AVAudioPlayerDelegate {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.ChunkedPlayer")

    /// One slot per expected chunk. Slots start `nil` and get filled in as the
    /// HTTP responses complete (which happens out of order).
    private var slots: [Data?] = []
    private var failedChunks: Set<Int> = []
    private var totalChunks: Int = 0
    private var nextChunkToPlay: Int = 0
    private var currentPlayer: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var volume: Float = 1.0
    private var rate: Float = 1.0
    private var isStopped = false
    private var isPaused = false

    /// Cumulative bytes played out of total received — coarse progress signal.
    private var chunksFinished: Int = 0

    var onProgress: ((Double) -> Void)?
    var onChunkFinished: ((Int) -> Void)?
    var onChunkFailed: ((Int) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    private var isBuffering = false

    var isPlaying: Bool {
        currentPlayer?.isPlaying ?? false
    }
    var isCurrentlyPaused: Bool {
        isPaused
    }

    /// Begin a playback session. `totalChunks` reserves the queue slots so
    /// out-of-order arrivals can drop into the right position.
    func start(
        totalChunks: Int,
        volume: Float,
        initialRate: Float,
        onReady: @MainActor () -> Void = {}
    ) async {
        stop()
        self.totalChunks = totalChunks
        self.volume = volume
        self.rate = initialRate
        self.slots = Array(repeating: nil, count: totalChunks)
        self.failedChunks.removeAll()
        self.nextChunkToPlay = 0
        self.chunksFinished = 0
        self.isStopped = false
        self.isPaused = false
        self.isBuffering = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            onReady()
            // We only resolve when either the last chunk finishes or stop() is called.
        }
    }

    /// Called by the provider when a chunk's HTTP request finishes. The
    /// chunk `index` is the position it was queued for; the queue plays them
    /// in strict index order regardless of arrival order.
    func supplyChunk(_ data: Data, at index: Int) {
        guard !isStopped, index >= 0, index < slots.count else { return }
        slots[index] = data
        startPlayingIfReady()
    }

    /// Provider signals that a chunk failed. We simply advance past it so
    /// playback doesn't stall forever waiting on a chunk that will never come.
    func skipChunk(at index: Int) {
        guard !isStopped, index >= 0, index < slots.count else { return }
        // Use empty data as a "played" marker to unblock the queue.
        slots[index] = Data()
        startPlayingIfReady()
    }

    func failChunk(at index: Int) {
        guard !isStopped, index >= 0, index < slots.count else { return }
        failedChunks.insert(index)
        slots[index] = Data()
        startPlayingIfReady()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        currentPlayer?.pause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        currentPlayer?.play()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        currentPlayer?.rate = max(0.5, min(2.0, newRate))
    }

    func stop() {
        isStopped = true
        setBuffering(false)
        currentPlayer?.stop()
        currentPlayer = nil
        slots.removeAll()
        failedChunks.removeAll()
        totalChunks = 0
        nextChunkToPlay = 0
        resolveContinuation()
    }

    // MARK: - Queue driving

    private func startPlayingIfReady() {
        // If we're already playing a chunk, do nothing — the delegate's
        // didFinishPlaying will call us again.
        guard currentPlayer == nil, !isStopped else { return }
        playNextIfAvailable()
    }

    private func playNextIfAvailable() {
        while nextChunkToPlay < totalChunks {
            guard let data = slots[nextChunkToPlay] else {
                setBuffering(nextChunkToPlay > 0)
                return
            }
            let index = nextChunkToPlay
            nextChunkToPlay += 1

            if data.isEmpty {
                if failedChunks.contains(index) {
                    setBuffering(false)
                    onChunkFailed?(index)
                    resolveContinuation()
                    return
                }
                // Chunk was marked skipped due to a failure — advance and try next.
                onChunkFinished?(index)
                continue
            }

            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.volume = max(0, min(1, volume))
                player.enableRate = true
                player.rate = max(0.5, min(2.0, rate))
                player.prepareToPlay()
                currentPlayer = player
                if !isPaused { player.play() }
                setBuffering(false)
                logger.debug("Playing chunk \(index)/\(self.totalChunks - 1)")
                return
            } catch {
                logger.warning("Failed to decode chunk \(index): \(error.localizedDescription, privacy: .public)")
                onChunkFailed?(index)
                resolveContinuation()
                return
            }
        }

        // Ran out of chunks to play in the queue right now.
        // If we've finished the last chunk, resolve. Otherwise wait for more.
        if nextChunkToPlay >= totalChunks {
            resolveContinuation()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.currentPlayer = nil
            self.chunksFinished += 1
            let finishedIndex = self.nextChunkToPlay - 1
            self.onChunkFinished?(finishedIndex)
            if self.totalChunks > 0 {
                self.onProgress?(min(1.0, Double(self.chunksFinished) / Double(self.totalChunks)))
            }
            if !self.isStopped {
                self.playNextIfAvailable()
            }
        }
    }

    private func resolveContinuation() {
        continuation?.resume()
        continuation = nil
    }

    private func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
        onBufferingChanged?(value)
    }
}
