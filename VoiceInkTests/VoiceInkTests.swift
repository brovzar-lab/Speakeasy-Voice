//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func backlogDocumentRoundTripsPendingCompletedAndMultilineEntries() throws {
        let pending = BacklogEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            text: "Make the button red.\nKeep contrast accessible.",
            createdAt: Date(timeIntervalSince1970: 1),
            completedAt: nil
        )
        let completed = BacklogEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            text: "Show version 1.5",
            createdAt: Date(timeIntervalSince1970: 2),
            completedAt: Date(timeIntervalSince1970: 3)
        )

        let source = BacklogDocument(entries: [pending, completed]).render()
        let parsed = try BacklogDocument.parse(source)

        #expect(parsed.entries == [pending, completed])
    }

    @Test func backlogDefaultPathUsesProvidedHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let url = BacklogFileLocator.defaultURL(homeDirectory: home)

        #expect(url.path == "/Users/example/CODE/SPEAKEASY-VOICE/BACKLOG.md")
    }

    @Test func backlogSubmissionTrimsTextAndRejectsEmptyDrafts() {
        #expect(FeatureBacklogSubmission.normalized("   ") == nil)
        #expect(FeatureBacklogSubmission.normalized("  Make it red. \n") == "Make it red.")
    }

    @Test @MainActor func backlogStoreReloadsExternalChangesBeforeAdding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("BACKLOG.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BacklogStore(fileURL: url)
        await store.load()

        let external = BacklogEntry(
            id: UUID(),
            text: "Added in Terminal",
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: nil
        )
        try Data(BacklogDocument(entries: [external]).render().utf8).write(to: url, options: .atomic)

        try await store.add(text: "Added in the app")
        let saved = try BacklogDocument.parse(String(contentsOf: url, encoding: .utf8))

        #expect(saved.entries.map(\.text) == ["Added in Terminal", "Added in the app"])
    }

    @Test @MainActor func backlogStoreEditsCompletesAndDeletesAnItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("BACKLOG.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BacklogStore(fileURL: url)
        await store.load()
        try await store.add(text: "Make it red")
        let id = try #require(store.entries.first?.id)

        try await store.edit(id: id, text: "Make it dark")
        #expect(store.entries.first?.text == "Make it dark")

        try await store.complete(id: id)
        #expect(store.entries.first?.isCompleted == true)

        try await store.delete(id: id)
        let saved = try BacklogDocument.parse(String(contentsOf: url, encoding: .utf8))
        #expect(saved.entries.isEmpty)
    }

    @Test func geminiSSEDecoderExtractsAudioFromCamelCasePayload() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let line = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\"AQIDBA==\"}}]}}]}".utf8)

        let event = try GeminiSSEEventDecoder.decode(line)

        #expect(event?.pcm == pcm)
        #expect(event?.finishReason == nil)
    }

    @Test func geminiSSEDecoderExtractsAudioFromSnakeCasePayload() throws {
        let pcm = Data([0x05, 0x06])
        let line = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"inline_data\":{\"data\":\"BQY=\"}}]}}]}".utf8)

        let event = try GeminiSSEEventDecoder.decode(line)

        #expect(event?.pcm == pcm)
    }

    @Test func geminiSSEDecoderReportsProviderTruncation() throws {
        let line = Data("data: {\"candidates\":[{\"finishReason\":\"OTHER\",\"content\":{\"parts\":[]}}]}".utf8)

        let event = try GeminiSSEEventDecoder.decode(line)

        #expect(event?.finishReason == "OTHER")
        #expect(event?.pcm == nil)
    }

    @Test func geminiSSEDecoderRejectsMalformedJSON() {
        let line = Data("data: {not-json}".utf8)

        #expect(throws: GeminiSSEDecodingError.self) {
            _ = try GeminiSSEEventDecoder.decode(line)
        }
    }

    @Test func geminiSSEDecoderAcceptsCRLFFraming() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let line = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\"AQIDBA==\"}}]}}]}\r".utf8)

        #expect(try GeminiSSEEventDecoder.decode(line)?.pcm == pcm)
        #expect(try GeminiSSEEventDecoder.decode(Data("\r".utf8)) == nil)
    }

    @Test func sentenceChunkerLeavesShortSelectionsAlone() {
        #expect(SentenceChunker.chunkIfNeeded("A short selection.") == nil)
    }

    @Test func sentenceChunkerBoundsLongGeminiRequests() throws {
        let sentence = "This sentence gives Gemini enough natural text to produce useful spoken audio. "
        let text = String(repeating: sentence, count: 25)

        let chunks = try #require(SentenceChunker.chunkIfNeeded(text))

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= SentenceChunker.maxChunkChars })
        #expect(chunks.joined(separator: " ") == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func sentenceChunkerHonorsProviderBoundaryAt751And1000Characters() throws {
        for length in [751, 1_000] {
            let chunks = try #require(SentenceChunker.chunkIfNeeded(String(repeating: "a", count: length)))
            #expect(chunks.allSatisfy { $0.count <= SentenceChunker.maxChunkChars })
        }
    }

    @Test func sentenceChunkerSplitsOversizedFirstSentenceBeforeMerging() throws {
        let longSentence = String(repeating: "word ", count: 170) + "."
        let text = longSentence + " Short ending."

        let chunks = try #require(SentenceChunker.chunkIfNeeded(text))

        #expect(chunks.allSatisfy { $0.count <= SentenceChunker.maxChunkChars })
    }

    @Test func segmentPlannerPrefersParagraphsAndPreservesContent() {
        let first = String(repeating: "First paragraph sentence. ", count: 18)
        let second = String(repeating: "Second paragraph sentence. ", count: 18)
        let text = first + "\n\n" + second

        let plan = ReadAloudSegmentPlanner.plan(text: text)

        #expect(plan.segments.count > 1)
        #expect(plan.segments.allSatisfy { !$0.text.isEmpty && $0.text.count <= 750 })
        #expect(plan.reconstructedText == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(plan.segments[0].text.hasSuffix("\n\n"))
    }

    @Test func segmentPlannerHardCapsUnbrokenText() {
        let plan = ReadAloudSegmentPlanner.plan(text: String(repeating: "a", count: 1_900))

        #expect(plan.segments.count == 3)
        #expect(plan.segments.allSatisfy { $0.text.count <= ReadAloudSegmentPlanner.maximumCharacters })
        #expect(plan.reconstructedText.count == 1_900)
    }

    @Test func rollingRecoveryNeverReplaysStartedSegment() {
        let position = RollingRecoveryPosition(
            completedThrough: 1,
            activeIndex: 2,
            activeAudioStarted: true
        )

        #expect(position.firstSafeFallbackIndex == 3)
    }

    @Test func rollingRecoveryRetriesUnheardActiveSegment() {
        let position = RollingRecoveryPosition(
            completedThrough: 1,
            activeIndex: 2,
            activeAudioStarted: false
        )

        #expect(position.firstSafeFallbackIndex == 2)
    }

    @Test func rollingWindowNeverExceedsTwoFutureSegments() {
        #expect(RollingPrefetchWindow.maximumFutureSegments == 2)
        #expect(RollingPrefetchWindow.indices(current: 2, total: 8) == [3, 4])
        #expect(RollingPrefetchWindow.indices(current: 6, total: 8) == [7])
    }

    @Test func orderedSegmentBufferWaitsForZeroWhenOneFinishesFirst() {
        var buffer = OrderedSegmentBuffer<Data>(count: 3)
        buffer.insert(Data([1]), at: 1)
        #expect(buffer.popNext() == nil)
        buffer.insert(Data([0]), at: 0)
        #expect(buffer.popNext() == Data([0]))
        #expect(buffer.popNext() == Data([1]))
    }

    @Test func bufferingRemainsAnActiveReadAloudState() {
        #expect(ReadAloudState.buffering.isActive)
        #expect(!ReadAloudState.idle.isActive)
    }

    @Test func fallbackTextBeginsAtTheFirstSafeSegment() throws {
        let plan = ReadAloudSegmentPlanner.plan(
            text: String(repeating: "A complete sentence. ", count: 100)
        )
        let second = try #require(plan.segments.indices.contains(1) ? plan.segments[1] : nil)

        #expect(plan.text(fromSegment: 1).hasPrefix(second.text))
    }

    @Test @MainActor func streamingStartupBarrierCompletesWhenStartupFinishes() async throws {
        var pendingChecks = 0
        let ready = try await StreamingStartupBarrier.waitUntilReady(
            timeout: 0.1,
            pollInterval: .milliseconds(1),
            isPending: {
                pendingChecks += 1
                return pendingChecks < 3
            }
        )

        #expect(ready)
    }

    @Test @MainActor func streamingStartupBarrierTimesOutWhenStartupStalls() async throws {
        let start = Date()
        let ready = try await StreamingStartupBarrier.waitUntilReady(
            timeout: 0.01,
            pollInterval: .milliseconds(1),
            isPending: { true }
        )

        #expect(!ready)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test @MainActor func cloudPCMChunksStayInOneContinuousStream() async {
        let first = AsyncStream<Data> { continuation in
            continuation.yield(Data([0x01, 0x02]))
            continuation.finish()
        }
        let second = AsyncStream<Data> { continuation in
            continuation.yield(Data([0x03, 0x04]))
            continuation.finish()
        }

        let stream = PCMStreamConcatenator.concatenate([first, second])
        var received: [Data] = []
        for await chunk in stream {
            received.append(chunk)
        }

        #expect(received == [Data([0x01, 0x02]), Data([0x03, 0x04])])
    }

    @Test @MainActor func delayedCloudChunkStillUsesOnePlaybackSession() async {
        let first = AsyncStream<Data> { continuation in
            continuation.yield(Data([0x01, 0x02]))
            continuation.finish()
        }
        let delayedSecond = AsyncStream<Data> { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(20))
                continuation.yield(Data([0x03, 0x04]))
                continuation.finish()
            }
        }

        var playbackSessions = 0
        var received: [Data] = []
        await PCMContinuousPlaybackCoordinator.play(streams: [first, delayedSecond]) { stream in
            playbackSessions += 1
            for await chunk in stream {
                received.append(chunk)
            }
        }

        #expect(playbackSessions == 1)
        #expect(received == [Data([0x01, 0x02]), Data([0x03, 0x04])])
    }

    @Test @MainActor func pcmPipelineInitiallyPreparesOnlyCurrentAndTwoFutureSegments() async {
        var requested: [Int] = []
        let stream = PCMStreamConcatenator.concatenate(count: 6) { index in
            requested.append(index)
            return PCMStreamSegment.wrapping(AsyncStream { continuation in
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    continuation.yield(Data([UInt8(index)]))
                    continuation.finish()
                }
            })
        }

        let consumer = Task { @MainActor in
            for await _ in stream { }
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(Set(requested) == Set([0, 1, 2]))
        consumer.cancel()
    }

    @Test func geminiFailureAfterAudioNeverReplaysFromBatch() {
        let resolved = GeminiStreamFailurePolicy.resolve(
            bytesPlayed: 48_000,
            underlying: .httpError(503, nil)
        )

        if case .streamEndedEarly = resolved {
            // Expected: the caller must stop rather than replay prior speech.
        } else {
            Issue.record("A post-audio failure must resolve to streamEndedEarly")
        }
    }

    @Test func ordinaryDictationFallsBackWithoutAnEnhancementWarning() {
        let ordinary = EnhancementExecutionPolicy.forDictation(isResponseMode: false)
        #expect(ordinary.timeoutOverride == 4)
        #expect(ordinary.retryOnTimeoutOverride == false)
        #expect(ordinary.maxAttemptsOverride == 1)
        #expect(!ordinary.showUserWarning)

        let response = EnhancementExecutionPolicy.forDictation(isResponseMode: true)
        #expect(response.timeoutOverride == nil)
        #expect(response.retryOnTimeoutOverride == nil)
        #expect(response.maxAttemptsOverride == nil)
        #expect(response.showUserWarning)
    }

    @Test func localCLIRespectsOrdinaryDictationDeadline() async {
        let suiteName = "VoiceInkTests.LocalCLIDeadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = LocalCLIService(defaults: defaults)
        service.commandTemplate = "sleep 1; echo enhanced"
        let start = Date()

        await #expect(throws: LocalCLIError.self) {
            _ = try await service.enhance(
                systemPrompt: "Clean this text",
                userPrompt: "hello",
                timeoutOverride: 0.05
            )
        }

        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func appVersionLabelUsesRequestedMarketingVersion() {
        #expect(AppVersionDisplay.text(version: "1.5") == "Version 1.5")
    }

    @Test func geminiRetriesTransientInternalErrorAndReturnsAudio() async throws {
        var attempts = 0
        var delays: [TimeInterval] = []

        let audio: Data = try await CloudTTSRetryPolicy.run(
            jitter: { $0 },
            sleep: { delays.append($0) },
            operation: { _ in
                attempts += 1
                if attempts < 3 {
                    throw CloudTTSError.httpError(
                        500,
                        #"{"error":{"code":500,"status":"INTERNAL"}}"#
                    )
                }
                return Data([0x01, 0x02])
            }
        )

        #expect(audio == Data([0x01, 0x02]))
        #expect(attempts == 3)
        #expect(delays == [0.5, 1.5])
    }

    @Test func geminiInternalErrorUsesConfiguredElevenLabsFallback() {
        let fallback = ReadAloudFallbackPolicy.resolve(
            primary: .gemini,
            preferred: .elevenlabs,
            isEnabled: true,
            configuredProviders: [.elevenlabs, .openai],
            error: .httpError(500, #"{"error":{"status":"INTERNAL"}}"#)
        )

        #expect(fallback == .elevenlabs)
    }

    @Test func partialAudioFailureNeverRestartsSelectionWithFallback() {
        let fallback = ReadAloudFallbackPolicy.resolve(
            primary: .gemini,
            preferred: .elevenlabs,
            isEnabled: true,
            configuredProviders: [.elevenlabs],
            error: .streamEndedEarly
        )

        #expect(fallback == nil)

        let authenticationFallback = ReadAloudFallbackPolicy.resolve(
            primary: .gemini,
            preferred: .elevenlabs,
            isEnabled: true,
            configuredProviders: [.elevenlabs],
            error: .httpError(401, "UNAUTHENTICATED")
        )
        #expect(authenticationFallback == nil)
    }

    @Test func rawProviderJSONIsNotShownToUser() {
        let message = ReadAloudErrorPresentation.message(
            provider: .gemini,
            error: CloudTTSError.httpError(
                500,
                #"{"error":{"code":500,"message":"An internal error has occurred","status":"INTERNAL"}}"#
            )
        )

        #expect(message == "Gemini is temporarily unavailable. Please try again.")
        #expect(!message.contains("{\"error\""))
    }

    @Test func selectedTextQueuePreservesReadingOrder() {
        var queue = ReadAloudTextQueue()
        queue.enqueue("First selection")
        queue.enqueue("Second selection")

        #expect(queue.count == 2)
        #expect(queue.dequeue() == "First selection")
        #expect(queue.dequeue() == "Second selection")
        #expect(queue.dequeue() == nil)
    }

    @Test func geminiDoesNotRetryInvalidRequest() async {
        var attempts = 0
        do {
            let _: Data = try await CloudTTSRetryPolicy.run(
                jitter: { $0 },
                sleep: { _ in },
                operation: { _ in
                    attempts += 1
                    throw CloudTTSError.httpError(400, "INVALID_ARGUMENT")
                }
            )
            Issue.record("A 400 response must fail without retrying")
        } catch {
            #expect(attempts == 1)
        }
    }

    @Test func cancellingGeminiRetryStopsImmediately() async {
        let task = Task<Data, Error> {
            try await CloudTTSRetryPolicy.run(
                jitter: { _ in 10 },
                operation: { _ in
                    throw CloudTTSError.httpError(500, "INTERNAL")
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancellation must stop pending Gemini retries")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test func geminiBatchRequestRetriesInternalResponsesAndDecodesAudio() async throws {
        let url = try #require(URL(string: "https://example.test/gemini"))
        let request = URLRequest(url: url)
        var attempts = 0
        var delays: [TimeInterval] = []
        let expectedPCM = Data([0x01, 0x02, 0x03, 0x04])
        let successBody = Data(
            #"{"candidates":[{"content":{"parts":[{"inlineData":{"data":"AQIDBA=="}}]}}]}"#.utf8
        )

        let pcm = try await GeminiBatchRequestExecutor.fetchPCM(
            request: request,
            jitter: { $0 },
            sleep: { delays.append($0) },
            transport: { _ in
                attempts += 1
                if attempts < 3 {
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                    return (Data(#"{"error":{"status":"INTERNAL"}}"#.utf8), response)
                }
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (successBody, response)
            }
        )

        #expect(pcm == expectedPCM)
        #expect(attempts == 3)
        #expect(delays == [0.5, 1.5])
    }

    @Test func fallbackStartsOnlyAfterGeminiRetriesAreExhausted() async throws {
        var geminiAttempts = 0
        var fallbackAttemptCount: Int?
        var spokenProviders: [ReadAloudProvider] = []

        let finalProvider = try await ReadAloudPlaybackRecovery.run(
            primary: .gemini,
            preferredFallback: .elevenlabs,
            fallbackEnabled: true,
            configuredProviders: [.elevenlabs],
            onFallback: { _ in fallbackAttemptCount = geminiAttempts },
            speak: { provider in
                spokenProviders.append(provider)
                if provider == .gemini {
                    let _: Data = try await CloudTTSRetryPolicy.run(
                        jitter: { $0 },
                        sleep: { _ in },
                        operation: { _ in
                            geminiAttempts += 1
                            throw CloudTTSError.httpError(500, "INTERNAL")
                        }
                    )
                }
            }
        )

        #expect(finalProvider == .elevenlabs)
        #expect(geminiAttempts == 3)
        #expect(fallbackAttemptCount == 3)
        #expect(spokenProviders == [.gemini, .elevenlabs])
    }

    @Test func cancellingGeminiRecoveryPreventsFallback() async {
        var fallbackCalls = 0
        let task = Task<ReadAloudProvider, Error> {
            try await ReadAloudPlaybackRecovery.run(
                primary: .gemini,
                preferredFallback: .elevenlabs,
                fallbackEnabled: true,
                configuredProviders: [.elevenlabs],
                onFallback: { _ in fallbackCalls += 1 },
                speak: { provider in
                    if provider == .elevenlabs { return }
                    let _: Data = try await CloudTTSRetryPolicy.run(
                        jitter: { _ in 10 },
                        operation: { _ in
                            throw CloudTTSError.httpError(500, "INTERNAL")
                        }
                    )
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = try? await task.value

        #expect(fallbackCalls == 0)
    }

    @Test func partialRecoveryContinuesFallbackAfterHeardSegments() async throws {
        var providers: [ReadAloudProvider] = []
        var startingSegments: [Int] = []

        let finalProvider = try await ReadAloudPlaybackRecovery.runSegmentAware(
            primary: .gemini,
            preferredFallback: .elevenlabs,
            fallbackEnabled: true,
            configuredProviders: [.elevenlabs],
            segmentCount: 4,
            onFallback: { _ in },
            speak: { provider, startingSegment in
                providers.append(provider)
                startingSegments.append(startingSegment)
                if provider == .gemini {
                    throw RollingTTSFailure(
                        firstSafeFallbackIndex: 2,
                        underlying: .streamEndedEarly
                    )
                }
            }
        )

        #expect(finalProvider == .elevenlabs)
        #expect(providers == [.gemini, .elevenlabs])
        #expect(startingSegments == [0, 2])
    }

    @Test @MainActor func usageAccumulatorCombinesSuccessfulRollingRequests() {
        let accumulator = ReadAloudUsageAccumulator(
            provider: "openai",
            model: "tts-1",
            voiceId: "nova"
        )

        accumulator.addSuccessfulRequest(characterCount: 500)
        accumulator.addSuccessfulRequest(characterCount: 250)

        #expect(accumulator.characterCount == 750)
    }

    @Test func geminiStreamingAndBatchFallbackShareThreeRequestBudget() {
        #expect(GeminiAttemptBudget.maximumStreamingThenBatchRequests == 3)
    }

}
