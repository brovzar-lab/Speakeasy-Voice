# Rolling Long-Text TTS Pipeline Design

**Date:** 2026-07-13
**Status:** Approved design

## Purpose

Long selected pages must begin speaking quickly and continue naturally without waiting for the entire page to synthesize. Speakeasy-Voice will split long selections at natural boundaries, play the first available audio immediately, and keep a bounded number of future sections ready in the background.

The user-visible result should feel like one continuous read. Paragraph boundaries must not stop the player or create a new read-aloud session.

## Current Behavior Being Replaced

- Gemini 3.1 streaming already divides large text and prepares one segment ahead, but the scheduling behavior is embedded in provider-specific code.
- Gemini 2.5 batch synthesis downloads every segment and concatenates all PCM before playback starts.
- OpenAI submits the entire selection as one batch MP3 request.
- ElevenLabs streams one request, but oversized selections still depend on a single long provider response.
- Existing whole-selection fallback can replay text from the beginning if failure recovery occurs after some audio has already been heard.

## Recommended Architecture

### Natural segment planning

`ReadAloudSegmentPlanner` converts a selection into ordered `ReadAloudSegment` values. It prefers, in order:

1. Blank-line paragraph boundaries
2. Sentence boundaries
3. Whitespace near the provider limit
4. A hard character boundary only when no safe whitespace exists

The target is 400–700 characters per segment, with an absolute 750-character maximum unless a provider has a smaller documented input limit. Text of 200 characters or fewer remains a single segment. No words or punctuation are removed, and joining the segment text reproduces the original spoken content.

### Bounded rolling preparation

`CloudTTSRollingPipeline` owns one ordered playback session:

- Segment 0 is requested immediately.
- Playback begins as soon as segment 0 yields playable audio.
- While segment N plays, the pipeline may prepare N+1 and N+2.
- It never has more than two future segments in flight or buffered.
- Completed segments are released from memory.
- Audio is consumed strictly in source order even if future requests finish out of order.
- Stop or skip cancels the current request and every prefetched request.

The two-segment window balances continuity against rate limits, memory, and wasted provider spend. It is an internal constant for the first release, not another user-facing setting.

### Provider adapters

Each cloud provider implements a segment-synthesis adapter while the rolling pipeline owns ordering and lifecycle:

- **Gemini 3.1:** Each segment remains an SSE PCM stream. PCM chunks from ordered segments feed the existing continuous audio engine.
- **Gemini 2.5:** Each batch request returns PCM for one segment. Segment 0 plays without waiting for the remainder; the current all-segments `combinedPCM` gate is removed.
- **ElevenLabs:** Each text segment uses streaming PCM. Ordered streams are concatenated inside one playback session. The batch fallback applies to the failed, not-yet-played segment rather than the full selection.
- **OpenAI:** Each segment requests MP3 independently. Results enter the existing ordered chunk player as they arrive, with only the two future slots prepared. Segment 0 starts before later MP3 responses complete.

Apple voices already begin locally without cloud synthesis and keep their current `AVSpeechSynthesizer` path.

### Session and progress state

`ReadAloudManager` continues to expose one selection as one session. It tracks the current segment index and the first unspoken segment.

`ReadAloudState` gains `.buffering`. The floating player remains visible and displays **Buffering next section** only when the current audio has drained before the next ordered segment is ready. When audio arrives, state returns to `.speaking` automatically.

Overall progress combines completed segments with the current segment’s playback progress, weighted by character count. Elapsed time continues to exclude initial loading, pauses, and buffering.

Pause, resume, live speed changes, skip, and stop apply to the entire rolling session. Speed changes affect both the active audio and every future segment.

## Failure and Fallback Rules

- A segment request that fails before playing audio uses the existing bounded transient retry policy.
- If retries are exhausted and automatic backup is enabled, fallback begins at the first unspoken segment, never at the beginning of the selection.
- A streaming segment that fails after partial audio is not replayed because doing so would repeat words. The UI reports the interruption and continues from the next natural segment when possible.
- Authentication, invalid-request, and missing-key errors do not retry.
- If no fallback is configured, the player shows a friendly provider error and stops without discarding separately queued selections.
- If synthesis falls behind but has not failed, the player enters `.buffering` rather than treating the session as complete.

The pipeline records the last fully completed segment and the active segment’s audio-start status so every recovery decision is explicit and testable.

## Usage Accounting

Segmenting must not make one selected page appear as many reads. A session-level usage accumulator records one usage row for the selection and provider, with the number of characters actually accepted by successful provider requests. Prefetched segments that produced a successful billable response are included even if the user stops before hearing them. Fallback-provider characters are recorded under that provider, without double-counting text synthesized by both providers.

## Components and File Boundaries

### `ReadAloudSegmentPlanner.swift`

Contains `ReadAloudSegment`, boundary detection, provider limits, and pure deterministic splitting logic.

### `CloudTTSRollingPipeline.swift`

Contains the bounded scheduler, ordered segment states, cancellation, buffering callbacks, segment-level recovery position, and session usage accumulation. It does not know about SwiftUI.

### Provider files

Provider-specific request construction remains with the provider. The current large `CloudTTSProvider.swift` may be split by provider only where needed to expose focused segment adapters; unrelated TTS code is not refactored.

### `ReadAloudManager.swift`

Maps pipeline callbacks into `.loading`, `.speaking`, `.buffering`, `.paused`, and `.idle`, and updates the floating indicator without starting a new session between segments.

### `ReadAloudIndicatorWindow.swift`

Adds the buffering label while preserving provider, elapsed time, queue count, speed, pause, skip, and stop controls.

## Concurrency and Memory Safety

- Network and audio decoding work stay off the main actor.
- AppKit, AVFoundation player mutation, and published state remain on the main actor.
- The PCM path continues yielding coarse `Data` chunks; byte-at-a-time MainActor streaming is prohibited because it previously crashed on macOS 26.
- Every request task belongs to one session identifier. Late results from a stopped or superseded session are ignored.
- The scheduler owns at most the active segment plus two future segments.
- Cancellation handlers close streams and stop audio before releasing player state.

## Testing

Planner tests prove:

- Short text stays in one segment.
- Paragraph boundaries are preferred.
- Long paragraphs fall back to sentences and whitespace.
- No segment exceeds its provider cap.
- Segment order and text content are preserved.

Pipeline tests use deterministic fake providers to prove:

- Segment 0 starts playing before segment 1 or 2 completes.
- Results that arrive out of order still play in order.
- No more than two future segments are requested.
- The next request begins while the current segment plays.
- Buffering begins and ends without completing the session.
- Stop and skip cancel all outstanding work.
- Pause and speed changes cross segment boundaries.
- A pre-playback transient error retries only its segment.
- Fallback resumes at the first unspoken segment.
- Partial-audio failure never replays heard text.
- Usage is aggregated per selection rather than counted as multiple reads.

Provider integration tests cover Gemini streaming PCM, Gemini batch PCM, ElevenLabs streaming plus segment batch fallback, and ordered OpenAI MP3 delivery. The existing full macOS unit and UI test suites must remain green.

## Success Criteria

- A long cloud selection begins speaking after the first segment is ready, without waiting for the full page.
- Normal paragraph and segment transitions are not perceived as stops.
- At most two future segments are prepared.
- No recovery path repeats already-heard text.
- The miniplayer remains one continuous session and clearly distinguishes buffering from completion.
- All provider work stops promptly when the user stops or skips.

## Out of Scope

- Persistent on-disk audio caching
- Offline cloud-voice playback
- User-configurable chunk size or prefetch depth
- Word-level highlighting or word-level recovery inside a partially failed cloud segment
- Changing provider pricing or voice selection
