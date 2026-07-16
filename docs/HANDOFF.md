# HANDOFF: Speakeasy-Voice

Last updated: 2026-07-16

## Current state

Speakeasy-Voice **1.7 build 204** is built and installed at `~/Downloads/Speakeasy-Voice.app`. Dictation remains working well. Read Aloud defaults to a free, on-device Kokoro voice, protects paid providers with a hard monthly limit, and uses a direct Float32 audio graph that fixes both the Gemini crash and silent Local HD playback.

## What shipped

### 1. Gemini and silent Local HD playback fix

- The July 15 crash report points to `AVAudioEngine.connect` inside `CloudTTSPlayer.setupPCMEngine`.
- Gemini and ElevenLabs supply signed 16-bit PCM. The old graph connected that wire format directly to `AVAudioUnitVarispeed`, which can throw `kAudioUnitErr_FormatNotSupported` and crash AVFAudio.
- `CloudPCMPlaybackFormat` converts PCM16 little-endian samples to mono, deinterleaved Float32 before scheduling them.
- A July 16 live app trace proved that even the Float32 `AVAudioUnitVarispeed` graph could fail to initialize with `-10868`, leaving Local HD silent. Streaming PCM now connects the player node directly to the main mixer.
- PCM speed is applied with pitch-preserving WSOLA time stretching before scheduling, and that work runs off the MainActor. This lets Local HD, Gemini, and ElevenLabs streaming voices speak faster without the chipmunk pitch shift. Do not restore the streaming effect unit, simple resampling, Int16 graph connections, or a forced network sample format at the mixer edge.
- Streaming still uses coarse `AsyncStream<Data>` chunks off the MainActor. Never return to byte-at-a-time MainActor work.

### 2. Free Local HD Read Aloud

- New provider: **Local HD (Free)** using `mlx-community/Kokoro-82M-bf16` through pinned `mlx-audio-swift` version `0.1.3`.
- One-time model download is about 360 MB. It runs on Apple Silicon with MLX/Metal, supports English and Spanish, and stays warm between reads.
- The model prepares both English and Spanish processors on load. Generation runs off the MainActor.
- Long text still uses the 400–750 character segment planner, but all generated Float32 samples feed one continuous audio session so there are no deliberate paragraph stops.
- Local HD is the new default. Existing installs migrate once with `readAloud.migratedLocalKokoroDefault_v1`.
- Automatic Backup uses only the explicitly chosen backup plus Local HD and Apple. It never invents a different paid provider. If Local HD cannot load, Apple is the final free fallback.
- Local benchmarks on this Mac: Kokoro warm English time-to-first-audio was about 0.74 seconds and generated a 9.12-second sample at about 12.3x realtime using roughly 312 MB. Qwen3-TTS was slower and used roughly 2.5 GB, so it was not integrated.

Research and source links: `docs/research/2026-07-15-local-tts-options.md`.

### 3. Paid cloud spending guard

- Read Aloud has a monthly hard limit, enabled by default at **$5**.
- Before any ElevenLabs, OpenAI, or Gemini request, the app estimates the remaining selection cost and blocks the request if it would cross the limit.
- Setting the limit to `$0` blocks every paid cloud voice. Local HD and Apple always remain usable.
- The setting lives in **Read Aloud → Usage & Budget** and can be turned off explicitly.
- The usage display includes Local HD at zero cost and changes color at 50%, 80%, and 100% of budget.
- Cost is estimated from the app's pricing table, not reconciled against provider invoices. Update both `estimatedCostUSD` and `pricingReference` when pricing changes.

### 4. Existing long-text and selection behavior

- `ReadAloudSegmentPlanner` splits long selections at paragraph/sentence boundaries into roughly 400–750 character sections, targeting 600.
- `CloudTTSRollingPipeline` prepares the current section and at most two future sections.
- PCM sections share one continuous playback session. MP3 sections remain ordered.
- Recovery begins at the first unheard section and never replays a section whose audio already started.
- Selecting new text interrupts the current reading by default. **Queue New Selections** is opt-in.
- The floating player supports ±5-second seek, pause/resume, next queued selection, stop, and speed control.

### 5. In-app feature backlog

- Settings includes **Feature Backlog**, stored in repository-root `BACKLOG.md` by default.
- Billy can add, edit, complete, delete, open, or switch the file.
- “Execute backlog” means process every pending item in the safest logical order without asking for one-by-one selection.

### 6. Version and build

- User-visible version: **1.7**.
- App target: `MARKETING_VERSION = 1.7`, build `204`.
- Keep bundle id, Swift module, UserDefaults keys, and internal `VoiceInk` names unchanged.
- Local builds use the stable self-signed `Speakeasy-Voice Local` identity.
- `make test` runs the deterministic signed unit suite. `make test-ui` is separate because macOS can time out while enabling UI automation before any test starts.

## Proof from this implementation pass

- `make local` completed with `** BUILD SUCCEEDED **` and copied version 1.7 to `~/Downloads/Speakeasy-Voice.app`.
- **55 unit tests passed**, including a pitch regression proving 440 Hz remains 440 Hz at 1.25×, 1.5×, 1.75×, and 2×, real audio-engine duration/speed checks, PCM format/conversion, Gemini recovery, free-provider fallback, local-to-Apple fallback, hard-budget blocking, long-text continuity, backlog, and version 1.7.
- The exact Float32 audio-engine graph starts successfully in a standalone AVFoundation proof.
- The installed bundle contains `default.metallib`, reports version 1.7, and remained running after relaunch.
- The optional UI runner timed out while macOS was enabling automation mode, before a UI test began. This is kept separate as `make test-ui`.

## Stability order

1. **Local HD**: recommended default, free and on-device after download.
2. **Apple**: most dependable emergency fallback, free, but lower voice quality.
3. **OpenAI `tts-1`**: stable paid batch API, slower startup for long text.
4. **ElevenLabs Flash v2.5**: fastest high-quality paid streaming option.
5. **Gemini 3.1 Flash preview**: improved by the crash fix and retries, but still the least predictable because the provider can return `INTERNAL` errors or truncate long generations.

## Known risks and guardrails

1. Google can truncate a single Gemini SSE request around 60 seconds with `finishReason: OTHER`. Keep the rolling segment pipeline.
2. Never schedule streaming PCM byte-by-byte on the MainActor.
3. Never replay already-heard content during recovery.
4. `APIKeyManager` must trim whitespace on save and load.
5. OpenAI `tts-1` and `tts-1-hd` accept only the nine base voices.
6. Local HD needs network access for its first model download. After it is cached, synthesis is local.
7. `README.md` still describes upstream VoiceInk and needs a separate public-facing rewrite.

## Key files

- `VoiceInk/ReadAloud/LocalTTSProvider.swift`: Kokoro model lifecycle and local synthesis
- `VoiceInk/ReadAloud/CloudTTSProvider.swift`: cloud APIs, PCM conversion, shared audio player
- `VoiceInk/ReadAloud/ReadAloudManager.swift`: orchestration and preflight budget check
- `VoiceInk/ReadAloud/ReadAloudSettings.swift`: providers, migration, fallback policy
- `VoiceInk/ReadAloud/ReadAloudUsageTracker.swift`: usage, estimates, hard-limit policy
- `VoiceInk/ReadAloud/ReadAloudSegmentPlanner.swift`: long-text boundaries
- `VoiceInk/Views/Settings/ReadAloudSettingsView.swift`: provider/model settings
- `VoiceInkTests/VoiceInkTests.swift`: regression suite
- `docs/research/2026-07-15-local-tts-options.md`: model research and benchmark evidence

## Run and verify

```bash
cd ~/CODE/SPEAKEASY-VOICE
make test
make local
open ~/Downloads/Speakeasy-Voice.app
```

No dev server or port is used; this is a native macOS menu-bar app.
