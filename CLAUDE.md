# Speakeasy-Voice

A local-first, system-wide AI voice app for macOS (a self-hosted Wispr Flow / WhisperFlow clone). Dictation and Apple speech run on-device; ElevenLabs, OpenAI, and Gemini are optional cloud voices for Read Aloud. Fork of VoiceInk (github.com/Beingpax/VoiceInk, GPLv3), owned by brovzar-lab/Speakeasy-Voice.

Native macOS SwiftUI menu-bar app (Xcode project, no `package.json`, no dev server / port). All commands run from `~/CODE/Speakeasy-Voice`.

## Commands
| Task | Command |
|------|---------|
| Prereqs | `brew install cmake` (Xcode + Swift also required) |
| Create local signing identity (once) | `make signing-cert` (auto-run by `make local`) |
| Build + run (local, no dev cert) | `make local && open ~/Downloads/Speakeasy-Voice.app` |
| Build only (unsigned Debug) | `make build` |
| Build + run (unsigned Debug) | `make dev` |
| Run last build | `make run` |
| Unit tests | `make test` |
| UI automation | `make test-ui` (macOS must allow automation mode) |
| Clean whisper deps | `make clean` (removes `~/VoiceInk-Dependencies` only) |

- `make local` is the default path here: signed with the stable self-signed `Speakeasy-Voice Local` identity (created once by `Scripts/create-local-signing-cert.sh` via the `signing-cert` target), no Apple Developer account, strips CloudKit/keychain entitlements, adds the `LOCAL_BUILD` compile flag, and copies `Speakeasy-Voice.app` to `~/Downloads`. The stable identity (not ad-hoc) is what lets macOS Accessibility/Input Monitoring grants survive rebuilds. `VoiceInk.local.entitlements` sets `com.apple.security.cs.disable-library-validation` because the project forces hardened runtime on and the self-signed frameworks would otherwise be rejected as "different Team IDs" and crash at launch. `make build`/`make dev` produce an unsigned Debug build (`CODE_SIGN_IDENTITY=""`) — not a signed dev build.
- First build clones + builds the whisper.cpp XCFramework into `~/VoiceInk-Dependencies` (outside the repo); later builds skip it. `make local` derived data goes to `.local-build/` in the repo (wiped each run).
- No lint tooling (no SwiftLint). `VoiceInkTests/VoiceInkTests.swift` now contains focused Swift Testing coverage for the backlog parser/store, Gemini recovery, rolling long-text playback, queue/interrupt behavior, seeking, usage tracking, and the app version.
- Always rebuild with `make local` and relaunch before claiming a change works.

## Stack
- Current user-visible version: **1.7** (`MARKETING_VERSION = 1.7`, build 202). The version appears below Settings in the sidebar.
- Speech-to-text: NVIDIA Parakeet v3 via the FluidAudio SPM package (chosen for strong English + Spanish). whisper.cpp also available (`Transcription/Whisper/`).
- AI cleanup: local Ollama model `gemma3:4b` at `http://localhost:11434` (`brew install ollama`, run via `brew services`). Ollama serves LLMs only — it does NOT do speech-to-text.
- New `.swift` files placed under `VoiceInk/` are auto-added to the target (PBXFileSystemSynchronizedRootGroup) — no need to edit the Xcode project.
- SPM deps (in `VoiceInk.xcodeproj/project.pbxproj`): FluidAudio, MLXAudioTTS 0.1.3, Sparkle, LLMkit, SelectedTextKit, mediaremote-adapter, swift-markdown-ui, Zip, LaunchAtLogin-Modern, swift-atomics.

## Naming — DO NOT break these
User-visible name is "Speakeasy-Voice", but the internals still say VoiceInk on purpose:
- Keep bundle id `com.prakashjoshipax.VoiceInk`, Swift module name `VoiceInk` (set via `PRODUCT_MODULE_NAME = VoiceInk`), type names (`VoiceInkEngine`, etc.), CloudKit container, UserDefaults keys, and window autosave names unchanged.
- Only `PRODUCT_NAME` is "Speakeasy-Voice" (that fixes CFBundleName / the menu bar / the .app filename). Xcode IGNORES `INFOPLIST_KEY_CFBundleName` and any CFBundleName in Info.plist while `GENERATE_INFOPLIST_FILE = YES`, so CFBundleName can only be changed through `PRODUCT_NAME`.

## Custom features (ours, added on top of the fork)
First-launch seeders all live in `VoiceInk/VoiceInk.swift`, each guarded by a UserDefaults flag so they run once:
- Custom dictionary of the owner's proper nouns — flag `hasSeededSpeakeasyDictionary_v1`.
- Ollama cleanup enabled on the default Dictation mode — flag `hasSeededOllamaCleanup_v1`.
- Style-preset cleanup prompts — flag `hasSeededStylePresets_v1`.
- Default (Clean) prompt migrated to minimal-cleanup wording — flag `hasMigratedMinimalCleanupPrompt_v1`.

Managers (in `VoiceInk/Modes/`), both read by `ModeRuntimeResolver` (enum in `ModeRuntimeConfiguration.swift`):
- `DictationLanguageManager.swift` — global EN/ES force-toggle from the menu bar or the `toggleDictationLanguage` hotkey, independent of any single mode. `ModeRuntimeResolver.transcriptionConfiguration` reads `forcedLanguage` and overrides the per-mode language.
- `StylePresetManager.swift` — cleanup styles Raw / Clean (keep my words) / Formal Email / Script Notes / WhatsApp-Casual. `ModeRuntimeResolver.currentEnhancementConfiguration` reads `activePreset` and overrides the enhancement prompt. Cycled via the `cycleDictationStyle` hotkey.
- `VoiceInk/Shortcuts/FnDoubleTapMonitor.swift` — listen-only CGEvent tap; double-tap Fn/Globe (keycode 63, `kVK_Function`) toggles recording. Default on; toggle in Settings.

### Read Aloud (text-to-speech, our own layer under `VoiceInk/ReadAloud/`)
Reverse of the dictation flow: read text back to the user instead of transcribing speech. Fully orthogonal to `VoiceInkEngine` — never touches the mic.
- `ReadAloudManager.swift` — `@MainActor` singleton orchestrator. States: `.idle` / `.capturing` / `.loading` / `.speaking` / `.buffering` / `.paused`. New selections interrupt the active read by default; the optional **Queue New Selections** setting restores ordered queueing. Rapid selection captures cancel older captures so the latest selection wins. Playback controls include pause/resume, stop, next queued selection, speed, and ±5-second seek.
- `TextToSpeechService.swift` — `TextToSpeechProvider` protocol + `AppleTTSProvider` (wraps `AVSpeechSynthesizer`). Providers expose `seek(by:)`. Apple tracks the spoken text offset and approximates a five-second seek by word position; it also restarts from the current word on live rate changes because `AVSpeechUtterance.rate` is immutable once started.
- `LocalTTSProvider.swift` — free on-device Local HD via Kokoro-82M and the pinned MLXAudioTTS 0.1.3 Swift package. The model is about 360 MB, supports English and Spanish voices, stays warm between reads, generates off MainActor, and feeds every planned section into one continuous Float32 playback session.
- `CloudTTSProvider.swift` — `ElevenLabsTTSProvider` prefers streaming PCM (`/v1/text-to-speech/{voice_id}/stream?output_format=pcm_16000&optimize_streaming_latency=4`) so playback starts before the full response arrives; falls back to batch mp3. `OpenAITTSProvider` uses batch mp3 (`/v1/audio/speech`). `GeminiTTSProvider` uses Gemini `generateContent` / `streamGenerateContent` (24 kHz PCM, 30 prebuilt voices; 3.1 Flash streams). Streaming feeds `AsyncStream<Data>` chunks decoded off the main actor (byte-at-a-time MainActor streaming crashed on macOS 26). Reuses the `"gemini"` API key from AI Models. All play through shared `CloudTTSPlayer`.
- `ReadAloudSegmentPlanner.swift` + `CloudTTSRollingPipeline.swift` — long selections are split at paragraph/sentence boundaries into roughly 400–750 character sections (target 600). Playback prepares the current section plus at most two future sections, then feeds one continuous PCM or ordered MP3 session. This makes long pages start quickly without paragraph-by-paragraph stops. Recovery resumes only from unheard content and never replays a section whose audio already started.
- `ReadAloudSettings.swift` — persisted preferences singleton. UserDefaults keys under `readAloud.*` (provider, localVoice, appleVoiceIdentifier, elevenLabsVoiceId, elevenLabsModelId, openAIVoice, openAIModel, rate, pitch).
- `ReadAloudUsageTracker.swift` — spend/usage bookkeeping singleton. Records one `ReadAloudUsageRecord` per successful read (any provider, including free Apple) with provider / model / voice / character count / cached USD cost estimate. Cost is computed at write-time from `ReadAloudUsageTracker.estimatedCostUSD(...)` so historical rows stay stable if the pricing table changes. Records persisted as JSON blob in UserDefaults under `readAloud.usageHistory`; pruned to 5000 records / 365 days. Aggregation API: `costToday` / `costThisWeek` / `costThisMonth` / `lifetimeCost`, `breakdownByProvider(since:)`, `mostUsedVoice(since:)`, `projectedMonthlyCost` (linear projection), and `budgetProgress` / `isOverBudget` gated on `monthlyBudgetUSD` (stored in `readAloud.monthlyBudgetUSD`, 0 = disabled).
- `ReadAloudUsageWidget.swift` — reusable SwiftUI view for the usage tracker. Two styles: `.compact` (sidebar tile, tappable to jump to Read Aloud settings) and `.expanded` (full-width form section with per-provider bars + budget field). The compact tile lives in `AppSidebar` between the primary items and Settings so spend is always visible without opening the tab.
- `ReadAloudIndicatorWindow.swift` — floating 420×44 `NSPanel` at top-right (statusBar level, non-activating). Shows status, rewind 5 seconds, pause/resume, forward 5 seconds, next queue item, stop, speed controls, and a bottom progress bar.
- `ScreenRegionSelectionController.swift` — full-screen borderless `NSPanel` overlay per display, drag-to-select rectangle, dimmed veil with cutout, live dimensions label, then ScreenCaptureKit + Vision OCR on the drawn region. Escape / right-click cancels.
- Providers: Local HD/Kokoro is the default free voice; Apple is the free emergency fallback. ElevenLabs, OpenAI, and Gemini are metered opt-in voices. Automatic recovery may use an explicitly chosen paid backup but never invents another paid provider. API keys are stored via `APIKeyManager` under provider ids `"elevenlabs"`, `"openai"`, and `"gemini"` (Gemini key is shared with transcription / AI cleanup).
- Shortcut actions: `.readSelectedText`, `.readScreenRegion`, `.stopReading` (all in `ShortcutAction.globalUtilityActions`).
- Settings UI: dedicated sidebar section `ViewType.readAloud` → `ReadAloudSettingsView`. Opens with an expanded **Usage & Budget** section (per-provider bars, monthly budget, recent reads) so the sidebar spend tile has somewhere useful to land. Voice picker for OpenAI auto-filters by model (tts-1 / tts-1-hd only support the 9 base voices; Ballad/Verse/Marin/Cedar are `gpt-4o-mini-tts`-only). ElevenLabs section links to `elevenlabs.io/app/voice-library` and provides a Quick Pick menu of preset voice IDs (Rachel, Adam, Bella, Antoni, Domi). Both cloud sections have a "Test" button that pings the provider's API to verify the key.
- Sidebar order (`ViewType.primaryItems` in `AppSidebar.swift`): Dashboard, Dictation Modes (raw value still `"Modes"` for navigation-notification compatibility, visible label overridden to `"Dictation Modes"`), Read Aloud, Transcribe, AI Models, Audio, Dictionary, History. Below the primary items sits the `ReadAloudUsageWidget` tile, then Settings in the secondary section.

### In-app feature backlog
- `VoiceInk/Backlog/BacklogDocument.swift` parses and preserves the Markdown backlog format, including UUID, added date, completion date, and multiline entries.
- `VoiceInk/Backlog/BacklogStore.swift` reloads external edits before every mutation and saves atomically. The default file is repository-root `BACKLOG.md`; users can choose another file and the security-scoped bookmark is persisted.
- `FeatureBacklogSettingsSection.swift` lives inside Settings and supports adding, editing, completing, deleting, opening, and switching backlog files.
- When Billy says **“execute backlog”**, process every pending item in the safest logical order without asking him to choose entries one by one. Test each item independently, then move it to Completed with the same UUID and a completion date. Stop only for destructive/irreversible work, spending, conflicts, or a genuine blocker.

## Key files & directories
- `VoiceInk/VoiceInk.swift` — `@main` app entry + all first-launch seeders.
- `Makefile` — the whole build system (`local` / `dev` / `build` / `whisper` / `clean`).
- `LocalBuild.xcconfig` — ad-hoc signing overrides + `LOCAL_BUILD` compile flag for `make local`.
- `VoiceInk/VoiceInk.local.entitlements` — stripped entitlements (no CloudKit/keychain) for local builds.
- `VoiceInk/Modes/` — modes, ModeManager, ModeRuntimeConfiguration, language/style managers, triggers.
- `VoiceInk/Shortcuts/` — shortcut system, ShortcutMonitor, FnDoubleTapMonitor, ShortcutMigration/Validator.
- `VoiceInk/Transcription/` — STT engines: `FluidAudio/` + `Streaming/` (Parakeet), `Whisper/`, `Engine/` (VoiceInkEngine, TranscriptionPipeline).
- `VoiceInk/ReadAloud/` — text-to-speech feature: orchestration, Apple/cloud providers, rolling segmentation/prefetch, player, usage, settings, and screen-region OCR.
- `VoiceInk/Backlog/` + `VoiceInk/Views/Settings/FeatureBacklogSettingsSection.swift` — Markdown-backed in-app feature backlog.
- `VoiceInk/Services/AIEnhancement/` — Ollama / AI cleanup layer (`OllamaService.swift` is under `Services/`).
- `VoiceInk/Services/` — audio devices, keychain, license, dictionary, import/export, session metrics.
- `VoiceInk/Views/` — SwiftUI UI (menu bar, settings, dashboard, onboarding).

## Environment
No `.env` — config is UserDefaults + Keychain, set at runtime in the app UI. Ollama must be reachable at `http://localhost:11434` for AI cleanup.

## Gotchas
- Permissions are per-binary, tied to the code-signing identity. Because `make local` now uses the stable `Speakeasy-Voice Local` identity, Accessibility/Input Monitoring grants persist across rebuilds. The one time you must re-grant is when switching an existing install from an old ad-hoc build to the stable-signed one: in System Settings > Privacy & Security, remove "Speakeasy-Voice" from Accessibility AND Input Monitoring with the "−" button, relaunch, and re-add. After that they stick. (Renaming the executable still invalidates grants.)
- For double-tap Fn, set System Settings > Keyboard > "Press 🌐 key to" → "Do Nothing" (otherwise Fn opens the emoji picker).
- Adding a new `ShortcutAction` case: also update `storageName`, `displayName`, `globalUtilityActions` (all in `ShortcutAction.swift`), `ShortcutMigration.legacyKeyboardShortcutsNames` (return `[]` for new actions), and `ShortcutValidator.allStoredActions`. A missing case breaks the exhaustive switch in `ShortcutMigration.swift`.
- Ollama cleanup silently no-ops if the Ollama server is not running; the app only pings it at transcription time.
- Local builds have no iCloud dictionary sync and no auto-update — pull new code and rebuild to update.
- `APIKeyManager.saveAPIKey` and `getAPIKey` both trim `.whitespacesAndNewlines`. Do NOT remove this — pasting a key from a webpage frequently drags a trailing `\n` along, and that newline ends up in the `Authorization: Bearer …` header, silently 401ing every request against an otherwise valid key. Whitespace-trimming on both save and load is the fix.
- OpenAI TTS voice ↔ model compatibility: `tts-1` and `tts-1-hd` only accept 9 voices (Alloy, Ash, Coral, Echo, Fable, Nova, Onyx, Sage, Shimmer). Ballad, Verse, Marin, Cedar are `gpt-4o-mini-tts`-only. `OpenAITTSVoices.voices(for:)` in `ReadAloudSettingsView.swift` is the source of truth; the Read Aloud settings view auto-snaps to a supported voice when the model changes and reconciles orphaned combos on `.onAppear`.
- Read Aloud live rate change: for Apple, we stop the current utterance and restart from `lastSpokenOffset` because `AVSpeechUtterance.rate` is immutable. For cloud mp3 (OpenAI / ElevenLabs batch), `AVAudioPlayer.enableRate = true` + `player.rate = ...`. For PCM (Gemini + ElevenLabs streaming), rate goes through `AVAudioUnitVarispeed` in the engine graph — `AVAudioPlayerNode.rate` alone is unreliable on macOS.
- Read Aloud speed tips: Apple (local) is instant; ElevenLabs Flash v2.5 + streaming is the fast cloud path; Gemini **3.1 Flash** streams via `streamGenerateContent?alt=sse` (PCM chunks off MainActor; default; one-time migration `readAloud.migratedGemini31Flash_v1` bumps prior 2.5 defaults). Gemini 2.5 Flash is cheapest but waits for the full clip. Turbo is slower at the same ElevenLabs price. One-time migration flag `readAloud.migratedElevenLabsFlash_v1` bumps stored Turbo users to Flash.
- Read Aloud long-form: Google’s 3.1 Flash SSE can truncate a single request around ~60s (`finishReason: OTHER`). Keep the rolling 400–750 character segmentation and two-section prefetch window. Do not turn a long selection back into one provider request, and never replay a section after its audio has started.
- Read Aloud MainActor crash (2026-07-10): byte-at-a-time PCM streaming on MainActor (Gemini, and the same pattern in ElevenLabs) corrupted executor checks on macOS 26. Fixed by `AsyncStream<Data>` chunks off MainActor in `CloudTTSProvider.swift`. Do not reintroduce per-byte MainActor streaming.
- Read Aloud AVFAudio crash (2026-07-15): connecting Gemini's interleaved Int16 wire format directly to `AVAudioUnitVarispeed` raised `kAudioUnitErr_FormatNotSupported (-10868)` and crashed inside `AVAudioEngine.connect`. `CloudPCMPlaybackFormat` now converts network PCM to deinterleaved native Float32 before graph scheduling. Keep the player-node → varispeed → mixer graph in Float32 for Gemini, ElevenLabs, and Local HD.
- Local HD model lifecycle: repository `mlx-community/Kokoro-82M-bf16`, runtime pinned to MLXAudioTTS 0.1.3. First use downloads about 360 MB and prewarms English and Spanish. Warm English time-to-first-audio measured 0.74s; Qwen was rejected at 3.64s and ~2.5 GB peak memory.
- Paid cloud budget: `readAloud.hardBudgetEnabled` defaults on and `readAloud.monthlyBudgetUSD` defaults to $5 for a new install. A value of $0 blocks every paid cloud request. The manager estimates the full remaining selection before sending and routes a blocked request to Local HD/Apple when automatic backup is enabled.
- Read Aloud selection behavior: the default is interrupt/replace, migrated once with `readAloud.migratedInterruptOnNewSelection_v1`. **Queue New Selections** is opt-in. Downloaded MP3 seeks exactly five seconds; Apple and live PCM approximate seek by text position and may rerender the remainder of a cloud selection.
- Dictation speed tips: keep **Real-time** on in the active mode; cycle style preset to **Raw** (or disable AI enhancement) to skip Ollama; use default paste (Cmd+V) not Direct Typing for long text; `KeepTranscriptionModelLoaded` (default on, AI Models → Advanced) avoids unloading Parakeet/Whisper after every session; `RecordingContextCaptureService` only runs clipboard/selection/screen probes the active mode actually uses for enhancement (screen OCR is expensive — don't enable unless needed).
- Read Aloud pricing table: `ReadAloudUsageTracker.estimatedCostUSD(...)` hardcodes provider rates as of 2026-07 (ElevenLabs $0.05/$0.10 per 1K chars, OpenAI $0.015/$0.030 per 1K chars). When providers update pricing, update this method AND the human-readable string in `pricingReference` AND the footer text in `ReadAloudSettingsView.usageSection`. Historical records aren't recomputed — cost is cached on each `ReadAloudUsageRecord` at write-time so past estimates stay stable.
- Read Aloud usage is only recorded after a *successful* HTTP 2xx response from cloud providers. Failed / cancelled / rate-limited requests don't count toward the spend estimate. Apple (local) reads are recorded with cost=$0 so "reads today" and "most used voice" stats cover local usage too.
- AI cleanup is minimal by default: `AIPrompts.enhancementSystemTemplate` + the Default (Clean) prompt keep the user's exact words and only strip fillers / fix grammar / punctuation / spelling. Style presets Email / Casual / Script Notes still request stronger transforms. Migration flag `hasMigratedMinimalCleanupPrompt_v1` overwrites the seeded Default prompt on existing installs.
- AI cleanup preamble stripping: small local LLMs (esp. `gemma3:4b`) tend to prefix their output with "Okay, here's the polished text:" even when the prompt forbids it. `AIEnhancementOutputFilter.filter(...)` runs regex-based preamble stripping (case-insensitive, anchored to `^`) as a defensive layer AFTER the `<thinking>` / `<reasoning>` scrubbing, so leaks that get past the prompt are cleaned before the text reaches paste/display.
- `PasteMethod.type` (Direct Typing, no clipboard): synthesizes text via `CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: ...)` with `keyboardSetUnicodeString(...)` in ~20-char UTF-16 chunks separated by 4ms sleeps. Bypasses `NSPasteboard` entirely — clipboard managers never see the transcript. `CursorPaster.performPasteSession` checks `method.usesClipboard` and short-circuits the clipboard snapshot / restore path when the user picks Direct Typing. Slower than Cmd+V on very long text (~200 chars/sec) but preserves the clipboard state, so it's the recommended choice for anyone using a clipboard-history tool.

## Git
- Remote: `brovzar-lab/Speakeasy-Voice`. This is the owner's personal fork; committing to `main` and pushing is fine. Do not force-push.

## Reference
- Original research and roadmap: `~/whisperflow-local-clone-plan.md`
- Current session handoff: `docs/HANDOFF.md`
- Rolling long-text design: `docs/superpowers/specs/2026-07-13-rolling-long-text-tts-design.md`
- In-app backlog design: `docs/superpowers/specs/2026-07-13-in-app-feature-backlog-design.md`
