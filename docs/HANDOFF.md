# HANDOFF — Speakeasy-Voice (2026-07-10)

## Where we left off

We were fixing Read Aloud crashes and Gemini speed on branch `cursor/read-aloud-speed-optimizations` (base: `main`).

Billy confirmed the crash was **Gemini-only** (Apple voices were fine). Root cause: Gemini 3.1 streaming fed PCM **one byte at a time on the MainActor**, which corrupted Swift’s main-thread checks on macOS 26 and crashed on the next UI click (`EXC_BAD_ACCESS` in `swift_task_isMainExecutorImpl` / `MainActor.assumeIsolated`).

Latest shipped fix (`d15ed4d`, pushed):
- Gemini streaming restored for speed
- PCM now arrives as `AsyncStream<Data>` chunks, decoded **off** the main actor
- Only buffer scheduling hops back to MainActor
- Batch `generateContent` remains the fallback if streaming fails
- ElevenLabs streaming also chunked the same way
- Parsing accepts both `inlineData` and `inline_data`

App was rebuilt with `make local` and launched from `~/Downloads/Speakeasy-Voice.app`. Billy was asked to retest Gemini 3.1 Flash; **no confirmation yet** that the new build is crash-free and feels fast enough.

Earlier on this branch (already committed): AppKit Read Aloud indicator, clipboard-only text capture for Read Aloud, usage/progress MainActor hardening, Gemini TTS provider, Varispeed rate control.

## Next action

Ask Billy to retest Gemini Read Aloud on the latest build, then act on the result:

1. Quit Speakeasy-Voice if running
2. `cd ~/CODE/SPEAKEASY-VOICE && make local && open ~/Downloads/Speakeasy-Voice.app`
3. Settings → Read Aloud → Provider **Gemini**, Model **3.1 Flash (fastest — streaming)**, any voice (Kore is fine)
4. Read a short selected paragraph, click around while it speaks

- If it works and starts quickly: merge/PR this branch into `main` when Billy asks
- If it still crashes: capture whether crash is during load, during speak, or on click; do **not** re-disable streaming without a new MainActor theory
- If it works but is still slow: measure time-to-first-sound; consider sentence chunking or defaulting cloud users to ElevenLabs Flash for snappiness

## Locked decisions

- User-visible name is Speakeasy-Voice; keep internal VoiceInk names / bundle id unchanged
- Build/run with `make local` → `~/Downloads/Speakeasy-Voice.app` (no dev server / port)
- Do not force-push; committing to this fork’s branches is fine
- Gemini crash fix must keep streaming **off MainActor in Data chunks** — do not revert to byte-at-a-time MainActor streaming
- Apple TTS path is the known-good baseline for “no crash”
- Read Aloud must stay orthogonal to `VoiceInkEngine` (no mic)
- API keys: always trim whitespace on save/load (`APIKeyManager`)

## Open loops

1. **Billy verification of `d15ed4d`** — Gemini 3.1: fast start + no crash. Done when Billy says it works (or reports exact failure mode).
2. **Branch not merged to `main`** — still on `cursor/read-aloud-speed-optimizations`. Done when PR merged or Billy says merge/push to main.
3. **Untracked local notes** — `.planning/debug/read-aloud-mainactor-crash.md` and `docs/audits/2026-07-07-audit.md` were left out of commits on purpose. Done when Billy says keep/delete/commit them.
4. **Long Gemini streams (~60s+)** — Google’s SSE path can truncate; batch fallback exists but may reintroduce wait. Done when long-read behavior is tested or documented as a known limit.
5. **ElevenLabs same crash class** — chunked now, but Billy never confirmed ElevenLabs. Done when briefly tested or marked N/A.

## How to run and verify

```bash
cd ~/CODE/SPEAKEASY-VOICE
make local
open ~/Downloads/Speakeasy-Voice.app
```

- Native macOS menu-bar app (Xcode). No `package.json`, no port.
- First build may compile whisper deps into `~/VoiceInk-Dependencies`.
- Permissions stick across rebuilds with the stable `Speakeasy-Voice Local` signing identity.
- Gemini needs the same `"gemini"` API key as AI Models (Settings → Read Aloud → Test).
- Ollama (`http://localhost:11434`) is for dictation cleanup only, not Read Aloud.

Key files:
- `VoiceInk/ReadAloud/CloudTTSProvider.swift` — Gemini/ElevenLabs/OpenAI + `CloudTTSPlayer`
- `VoiceInk/ReadAloud/ReadAloudManager.swift` — orchestrator
- `VoiceInk/ReadAloud/ReadAloudIndicatorWindow.swift` — AppKit floating controls
- `VoiceInk/Services/SelectedTextService.swift` — clipboard Cmd+C path for Read Aloud
- `VoiceInk/Views/Settings/ReadAloudSettingsView.swift` — provider/voice UI
- `CLAUDE.md` — project conventions (keep in sync if behavior changes)

## Gotchas / context not on disk

- Crash signature was always MainActor/Swift concurrency on macOS 26.5.1; HIServices Accessibility noise often appeared but was a red herring once Billy proved Apple voices never crashed.
- Temporarily disabling Gemini streaming fixed stability but made Read Aloud feel too slow; that is why streaming was restored the safe way.
- Billy is non-engineer: plain language, plan → approve → build → proof (`make local` + relaunch before claiming a fix works).
- Do not commit unless asked (this handoff file is the exception per `/handoff`).
- Remote: `brovzar-lab/Speakeasy-Voice`. Latest push on this branch: `d15ed4d`.
- When Billy asks “where did we leave off?”, read this file first and answer from **Next action** + **Open loops**.
