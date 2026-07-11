# Debug: read-aloud-mainactor-crash

**Status:** CLOSED (fix shipped in `d15ed4d`, 2026-07-10)  
**Date:** 2026-07-10

## Final root cause

Gemini-only. Apple voices never crashed.

Gemini 3.1 Flash streaming fed PCM **one byte at a time on the MainActor**
(`playStreamingPCM` + `AsyncSequence` of `UInt8`). On macOS 26 that corrupted
Swift’s MainActor executor checks; the next SwiftUI button click died in
`MainActor.assumeIsolated` / `swift_task_isMainExecutorImpl`.

Earlier Accessibility / SelectedTextKit theories were red herrings (HIE noise
often appeared nearby but Apple TTS used the same UI and did not crash).

## Fix shipped

- Stream PCM as `AsyncStream<Data>` chunks
- Decode / accumulate **off** MainActor (`Task.detached`)
- Hop to MainActor only to schedule audio buffers
- Batch `generateContent` remains fallback
- Same chunking applied to ElevenLabs streaming
- Accept both `inlineData` and `inline_data` in Gemini JSON

## Known limit (documented, not a crash)

Google’s Gemini 3.1 `streamGenerateContent` SSE can truncate audio around
~60s of speech (`finishReason: OTHER`). Batch path is more reliable for
very long reads but waits for the full clip.

## Verify (human)

1. Provider Gemini, model 3.1 Flash, any voice
2. Read a short paragraph — speech should start soon
3. Click around Speakeasy UI while / after speaking — no crash
