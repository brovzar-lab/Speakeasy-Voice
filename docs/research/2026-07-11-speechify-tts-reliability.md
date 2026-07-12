# Speechify-style TTS reliability research

Date: 2026-07-11

## Observed Speakeasy failure

Speakeasy-Voice logged the same Gemini failure twice on 2026-07-11, at 18:49:04 and 18:49:20:

- HTTP status: `500`
- Gemini status: `INTERNAL`
- Selected provider: Gemini
- Selected model: `gemini-2.5-flash-preview-tts`
- Selected voice: `Erinome`

This is not an invalid API key or a local audio-player crash. Google accepted the request and failed while generating the audio.

The current `GeminiTTSProvider.batchPCM` implementation makes one REST request and immediately throws on a non-2xx response. It does not retry transient failures. `ReadAloudManager` then presents the full localized error, and `CloudTTSError.httpError` includes the raw provider response body. Together, these choices create the raw JSON banner shown by the user.

## Primary-source findings

### Google Gemini

- Google defines `500 INTERNAL` as an unexpected error on Google's side. It recommends waiting and retrying, reducing the input, checking service status, or temporarily switching models.
- For direct REST integrations, Google recommends retrying transient `408`, `429`, and `5xx` failures with exponential backoff, jitter, and a maximum attempt count.
- Gemini TTS models are Preview. Streaming begins with Gemini 3.1; Gemini 2.5 TTS is batch-only.
- Google recommends smaller chunks for longer TTS output. It explicitly documents automated retry as necessary for an occasional random 500 condition in the 3.1 Preview model.

Sources:

- [Gemini API troubleshooting](https://ai.google.dev/gemini-api/docs/troubleshooting)
- [Gemini speech generation](https://ai.google.dev/gemini-api/docs/generate-content/speech-generation)

### Speechify

- Speechify's streaming API starts playback as audio chunks arrive instead of waiting for full generation.
- Speechify documents that a synthesis error after a stream begins can close the connection without a structured error. Its recommended client behavior is to count received audio and retry the remaining text.
- Speechify uses raw PCM for its lowest-latency streaming path.
- The Speechify Mac product exposes voice and speed controls in both the main window and a miniplayer.
- The supplied screenshots also show `Enqueue Selected Text`, a persistent miniplayer, voice search, and per-voice preview. Those are direct product observations, not claims about Speechify's internal implementation.

Sources:

- [Speechify streaming API](https://docs.speechify.ai/docs/features/streaming)
- [Speechify for Mac](https://speechify.com/mac/)
- [Speechify Mac guide](https://speechify.com/blog/ultimate-guide-to-the-speechify-mac-app-for-text-to-speech/)

## Recommended implementation

### Reliability first

1. Add a pure retry policy for transient Gemini errors only: `408`, `429`, and `5xx`.
2. Retry the failed sentence chunk up to two times with short exponential backoff and jitter.
3. Never retry authentication or malformed-request failures such as `400`, `401`, or `403`.
4. Preserve one continuous playback session. Retry only the failed or remaining chunk, never restart the full selection after audio has played.
5. After retry exhaustion, optionally continue with a configured backup provider. Recommend ElevenLabs Flash v2.5, then OpenAI `tts-1`. Do not silently fall back to Apple unless the user enables it.
6. Parse provider errors into a short message such as `Gemini is temporarily unavailable. Retrying...`; retain the detailed JSON only in diagnostics.
7. Log provider, model, chunk index, attempt, status code, and bytes played. Never log API keys.

### Speechify-inspired workflow

1. Add an `Enqueue selected text` preference so a new selection can append instead of replacing current playback.
2. Upgrade the existing floating player with elapsed time, queue count, previous/next, provider, and a retry/fallback status.
3. Add searchable voices with one-click previews.
4. Consider synchronized text highlighting as a later phase because it requires word-level timing support from each provider.

## Regression signal

Before implementation, add deterministic tests that inject a Gemini `500 INTERNAL` response and verify:

- the failed chunk is retried;
- the complete selection is not replayed;
- fallback starts only after retries are exhausted;
- raw provider JSON is not shown to the user;
- cancellation stops pending retries and fallback immediately.
