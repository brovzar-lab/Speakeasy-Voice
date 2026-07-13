import Foundation

enum RollingSegmentEvent: Equatable, Sendable {
    case startedPreparing(Int)
    case audioStarted(Int)
    case completed(Int)
    case buffering(Int)
    case resumed(Int)
}

struct RollingTTSFailure: LocalizedError {
    let firstSafeFallbackIndex: Int
    let underlying: CloudTTSError

    var errorDescription: String? { underlying.errorDescription }
}

struct RollingRecoveryPosition: Equatable, Sendable {
    var completedThrough: Int
    var activeIndex: Int?
    var activeAudioStarted: Bool

    var firstSafeFallbackIndex: Int {
        guard let activeIndex else { return max(0, completedThrough + 1) }
        return activeAudioStarted ? activeIndex + 1 : activeIndex
    }
}

enum RollingPrefetchWindow {
    static let maximumFutureSegments = 2

    static func indices(current: Int, total: Int) -> [Int] {
        guard total > 0, current + 1 < total else { return [] }
        let end = min(total - 1, current + maximumFutureSegments)
        return Array((current + 1)...end)
    }
}

struct OrderedSegmentBuffer<Element> {
    private var slots: [Element?]
    private var nextIndex = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: max(0, count))
    }

    mutating func insert(_ element: Element, at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = element
    }

    mutating func popNext() -> Element? {
        guard slots.indices.contains(nextIndex), let element = slots[nextIndex] else { return nil }
        slots[nextIndex] = nil
        nextIndex += 1
        return element
    }
}

@MainActor
final class RollingMP3Session {
    typealias Prepare = @MainActor @Sendable (Int) async throws -> Data

    private let count: Int
    private let player: CloudTTSChunkedPlayer
    private let volume: Float
    private let rate: Float
    private let prepare: Prepare
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextToPrepare = 0
    private var failureErrors: [Int: CloudTTSError] = [:]
    private var terminalFailureIndex: Int?

    init(
        count: Int,
        player: CloudTTSChunkedPlayer,
        volume: Float,
        rate: Float,
        prepare: @escaping Prepare
    ) {
        self.count = count
        self.player = player
        self.volume = volume
        self.rate = rate
        self.prepare = prepare
    }

    func run() async throws {
        guard count > 0 else { return }
        player.onChunkFinished = { [weak self] _ in
            self?.fillOneFutureSlot()
        }
        player.onChunkFailed = { [weak self] index in
            self?.terminalFailureIndex = index
        }

        await player.start(totalChunks: count, volume: volume, initialRate: rate) { [weak self] in
            self?.fillInitialWindow()
        }

        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        player.onChunkFinished = nil
        player.onChunkFailed = nil
        try Task.checkCancellation()
        if let terminalFailureIndex {
            throw RollingTTSFailure(
                firstSafeFallbackIndex: terminalFailureIndex,
                underlying: failureErrors[terminalFailureIndex] ?? .decodingFailed
            )
        }
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        player.stop()
    }

    private func fillInitialWindow() {
        let initialCount = min(count, RollingPrefetchWindow.maximumFutureSegments + 1)
        for _ in 0..<initialCount { launchNext() }
    }

    private func fillOneFutureSlot() {
        guard failureErrors.isEmpty else { return }
        launchNext()
    }

    private func launchNext() {
        guard nextToPrepare < count else { return }
        let index = nextToPrepare
        nextToPrepare += 1
        tasks[index] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await self.prepare(index)
                try Task.checkCancellation()
                self.player.supplyChunk(data, at: index)
            } catch is CancellationError {
                self.player.skipChunk(at: index)
            } catch {
                self.failureErrors[index] = (error as? CloudTTSError) ?? .invalidResponse
                self.player.failChunk(at: index)
            }
            self.tasks[index] = nil
        }
    }
}
