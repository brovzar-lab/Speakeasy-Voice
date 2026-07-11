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

}
