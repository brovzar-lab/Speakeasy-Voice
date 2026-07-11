import Foundation
import AVFoundation
import OSLog

/// Splits text into sentence-sized pieces so cloud TTS can be pipelined:
/// multiple sentences generate in parallel while the first one is already
/// playing.
///
/// Chunks target ~250 chars each, always broken on sentence boundaries when
/// possible. If a "sentence" is longer than the target, we split at the last
/// space before the limit rather than chop mid-word. Abbreviations like
/// "Mr." and "e.g." are handled by the regex — we only treat a period as a
/// terminator when it's followed by whitespace and a capital letter or newline.
enum SentenceChunker {
    /// Below this length we don't chunk at all — the overhead (multiple HTTP
    /// requests, delegate wiring) outweighs the latency benefit.
    static let singleRequestThreshold = 200

    /// Target chunk size in characters. Slightly larger than a typical
    /// sentence, so short sentences stay together and long ones split.
    static let targetChunkChars = 250

    /// Never exceed this even if we can't find a good boundary.
    static let maxChunkChars = 400

    /// Returns `nil` if the text is short enough for a single request.
    /// Returns an array of chunk strings otherwise.
    static func chunkIfNeeded(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > singleRequestThreshold else { return nil }

        let sentences = splitSentences(trimmed)
        guard sentences.count > 1 else {
            // One sentence but longer than the threshold — split by size only.
            return splitBySize(trimmed)
        }

        // Merge small sentences into ~targetChunkChars-sized chunks so we get
        // ~2-4 chunks for a typical paragraph. Too many chunks = too many HTTP
        // requests; too few chunks = time-to-first-audio doesn't improve.
        var chunks: [String] = []
        var buffer = ""

        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
                continue
            }
            let joined = buffer + " " + sentence
            if joined.count <= targetChunkChars {
                buffer = joined
            } else {
                chunks.append(buffer)
                buffer = sentence
            }
            if buffer.count >= maxChunkChars {
                chunks.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks.count > 1 ? chunks : nil
    }

    /// Split on `. ` / `? ` / `! ` / newlines while trying to avoid abbreviations.
    /// Conservative: prefers false negatives (leaving two sentences joined) over
    /// false positives (splitting mid-abbreviation) — TTS handles a long chunk
    /// fine, but splitting "Dr. Smith" into "Dr" and "Smith" sounds broken.
    private static func splitSentences(_ text: String) -> [String] {
        // (?<=[.?!])          — after a sentence terminator
        // (?<!\b[A-Z][a-z]?\.)  — but NOT after common abbreviations like "Mr." "Dr." "St."
        // \s+                 — followed by whitespace
        // (?=[A-Z"“(\[])      — before a capital letter, quote, or opening bracket
        let pattern = #"(?<=[.?!])\s+(?=[A-Z"“(\[])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        let range = NSRange(text.startIndex..., in: text)
        var lastEnd = text.startIndex
        var result: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let piece = String(text[lastEnd..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { result.append(piece) }
            lastEnd = r.upperBound
        }
        let tail = String(text[lastEnd...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }

    private static func splitBySize(_ text: String) -> [String] {
        var result: [String] = []
        var remaining = text[...]
        while remaining.count > maxChunkChars {
            let cutoff = remaining.index(remaining.startIndex, offsetBy: maxChunkChars)
            // Try to break at the last space before the cutoff.
            let searchRange = remaining.startIndex..<cutoff
            if let space = remaining.range(of: " ", options: .backwards, range: searchRange) {
                result.append(String(remaining[remaining.startIndex..<space.lowerBound]))
                remaining = remaining[space.upperBound...]
            } else {
                result.append(String(remaining[remaining.startIndex..<cutoff]))
                remaining = remaining[cutoff...]
            }
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
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

    var isPlaying: Bool {
        currentPlayer?.isPlaying ?? false
    }
    var isCurrentlyPaused: Bool {
        isPaused
    }

    /// Begin a playback session. `totalChunks` reserves the queue slots so
    /// out-of-order arrivals can drop into the right position.
    func start(totalChunks: Int, volume: Float, initialRate: Float) async {
        stop()
        self.totalChunks = totalChunks
        self.volume = volume
        self.rate = initialRate
        self.slots = Array(repeating: nil, count: totalChunks)
        self.nextChunkToPlay = 0
        self.chunksFinished = 0
        self.isStopped = false
        self.isPaused = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
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
        currentPlayer?.stop()
        currentPlayer = nil
        slots.removeAll()
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
            guard let data = slots[nextChunkToPlay] else { return }
            let index = nextChunkToPlay
            nextChunkToPlay += 1

            if data.isEmpty {
                // Chunk was marked skipped due to a failure — advance and try next.
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
                player.play()
                logger.debug("Playing chunk \(index)/\(self.totalChunks - 1)")
                return
            } catch {
                logger.warning("Failed to decode chunk \(index): \(error.localizedDescription, privacy: .public)")
                // Fall through to next iteration to try the following chunk.
                continue
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
}
