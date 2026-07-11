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

}
