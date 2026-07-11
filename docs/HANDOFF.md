# HANDOFF — Speakeasy-Voice (2026-07-10)

## Where we left off

Read Aloud Gemini crash + speed work on `cursor/read-aloud-speed-optimizations` is **code-complete and pushed**. Open loops from the earlier handoff were closed in this session (notes filed, limits documented, API smoke-tested, PR opened).

**Root cause (locked):** Gemini-only crash. Streaming PCM one byte at a time on the MainActor corrupted Swift’s executor checks on macOS 26. Apple voices never hit that path.

**Fix (shipped `d15ed4d`):** `AsyncStream<Data>` chunks decoded off MainActor; schedule buffers on MainActor only; batch fallback; same chunking for ElevenLabs; `inlineData` / `inline_data` parsing.

**API smoke test (2026-07-10, Billy’s saved Gemini key, voice Laomedeia):**
- Batch `generateContent`: HTTP 200, ~2.6s, PCM present
- Stream `streamGenerateContent?alt=sse`: HTTP 200, first PCM ~2.0s, PCM present

Settings already point at Gemini / 3.1 Flash / Laomedeia on this Mac.

## Next action

One human UI check, then merge the PR:

1. `cd ~/CODE/SPEAKEASY-VOICE && make local && open ~/Downloads/Speakeasy-Voice.app`
2. Select a short paragraph → Read Aloud (Gemini should already be selected)
3. Confirm speech starts in a couple seconds and clicking Speakeasy UI does not crash
4. Merge PR #1 into `main`: https://github.com/brovzar-lab/Speakeasy-Voice/pull/1

If step 3 fails, do **not** re-disable streaming; capture whether it fails on load, during speak, or on click, and reopen from `docs/HANDOFF.md`.

## Locked decisions

- Keep Speakeasy-Voice product name; keep VoiceInk internal names / bundle id
- Build with `make local` → `~/Downloads/Speakeasy-Voice.app`
- Gemini/ElevenLabs streaming must stay **Data chunks off MainActor** (never per-byte on MainActor)
- Apple TTS is the no-crash baseline
- Read Aloud stays orthogonal to `VoiceInkEngine` (no mic)
- Trim API keys on save and load
- Long Gemini reads (~60s+) may truncate on Google’s SSE; treat as known provider limit

## Open loops

None blocking. Optional follow-ups only:

1. **Human UI confirm** — one Gemini Read Aloud pass in the app (API already green). Done when Billy says “works” or reports a failure mode.
2. **Merge PR #1** — https://github.com/brovzar-lab/Speakeasy-Voice/pull/1 — merge when UI confirm is good (or when Billy says merge anyway).

## How to run and verify

```bash
cd ~/CODE/SPEAKEASY-VOICE
make local
open ~/Downloads/Speakeasy-Voice.app
```

- No dev server / port (native macOS app)
- Gemini key is the same `"gemini"` key as AI Models (local builds store under `LocalKeychain_geminiAPIKey` in app defaults)
- Debug write-up: `.planning/debug/read-aloud-mainactor-crash.md`
- Prior quick audit (unrelated to this crash): `docs/audits/2026-07-07-audit.md`

Key files:
- `VoiceInk/ReadAloud/CloudTTSProvider.swift`
- `VoiceInk/ReadAloud/ReadAloudManager.swift`
- `VoiceInk/ReadAloud/ReadAloudIndicatorWindow.swift`
- `VoiceInk/Services/SelectedTextService.swift`
- `CLAUDE.md`

## Gotchas / context not on disk

- Billy’s Mac already has `readAloud.provider = gemini`, model `gemini-3.1-flash-tts-preview`, voice `Laomedeia`
- HIE / Accessibility noise in crash logs was a red herring once Apple vs Gemini was compared
- Temporary “batch-only Gemini” fix stopped crashes but made Read Aloud feel too slow; streaming was restored the safe way
- When asked “where did we leave off?”, read this file and start at **Next action**
