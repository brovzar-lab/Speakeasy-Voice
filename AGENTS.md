# Speakeasy-Voice

A fully-local, system-wide AI voice dictation app for macOS (a self-hosted Wispr Flow / WhisperFlow clone). Trigger a shortcut, speak, and clean text is auto-typed into whatever app has focus. Everything runs on-device: no cloud. Fork of VoiceInk (github.com/Beingpax/VoiceInk, GPLv3), owned by brovzar-lab/Speakeasy-Voice.

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
| Test | `xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS'` |
| Clean whisper deps | `make clean` (removes `~/VoiceInk-Dependencies` only) |

- `make local` is the default path here: signed with the stable self-signed `Speakeasy-Voice Local` identity (created once by `Scripts/create-local-signing-cert.sh` via the `signing-cert` target), no Apple Developer account, strips CloudKit/keychain entitlements, adds the `LOCAL_BUILD` compile flag, and copies `Speakeasy-Voice.app` to `~/Downloads`. The stable identity (not ad-hoc) is what lets macOS Accessibility/Input Monitoring grants survive rebuilds. `VoiceInk.local.entitlements` sets `com.apple.security.cs.disable-library-validation` because the project forces hardened runtime on and the self-signed frameworks would otherwise be rejected as "different Team IDs" and crash at launch. `make build`/`make dev` produce an unsigned Debug build (`CODE_SIGN_IDENTITY=""`) — not a signed dev build.
- First build clones + builds the whisper.cpp XCFramework into `~/VoiceInk-Dependencies` (outside the repo); later builds skip it. `make local` derived data goes to `.local-build/` in the repo (wiped each run).
- No lint tooling (no SwiftLint). Tests are the default Swift Testing stub only (`import Testing`, one empty `@Test`) — no real coverage.
- Always rebuild with `make local` and relaunch before claiming a change works.

## Stack
- Speech-to-text: NVIDIA Parakeet v3 via the FluidAudio SPM package (chosen for strong English + Spanish). whisper.cpp also available (`Transcription/Whisper/`).
- AI cleanup: local Ollama model `gemma3:4b` at `http://localhost:11434` (`brew install ollama`, run via `brew services`). Ollama serves LLMs only — it does NOT do speech-to-text.
- New `.swift` files placed under `VoiceInk/` are auto-added to the target (PBXFileSystemSynchronizedRootGroup) — no need to edit the Xcode project.
- SPM deps (in `VoiceInk.xcodeproj/project.pbxproj`): FluidAudio, Sparkle, LLMkit, SelectedTextKit, mediaremote-adapter, swift-markdown-ui, Zip, LaunchAtLogin-Modern, swift-atomics.

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
- `ReadAloudManager.swift` — `@MainActor` singleton orchestrator. States: `.idle` / `.capturing` / `.loading` / `.speaking` / `.paused`. Public API: `readSelectedText()`, `readScreenRegion()`, `preview(text:)`, `togglePlayback()`, `pause()`, `resume()`, `stop()`, `slower()` / `faster()` (0.1 steps, clamped 0.5×–2.0×).
- `TextToSpeechService.swift` — `TextToSpeechProvider` protocol + `AppleTTSProvider` (wraps `AVSpeechSynthesizer`). Apple provider tracks `lastSpokenOffset` from the delegate and restarts the utterance from the current word position on live rate change, since `AVSpeechUtterance.rate` is immutable once started.
- `CloudTTSProvider.swift` — `ElevenLabsTTSProvider` prefers streaming PCM (`/v1/text-to-speech/{voice_id}/stream?output_format=pcm_16000&optimize_streaming_latency=4`) so playback starts before the full response arrives; falls back to batch mp3. `OpenAITTSProvider` uses batch mp3 (`/v1/audio/speech`). `GeminiTTSProvider` uses Gemini `generateContent` / `streamGenerateContent` (24 kHz PCM, 30 prebuilt voices; 3.1 Flash streams). Streaming feeds `AsyncStream<Data>` chunks decoded off the main actor (byte-at-a-time MainActor streaming crashed on macOS 26). Reuses the `"gemini"` API key from AI Models. All play through shared `CloudTTSPlayer`.
- `ReadAloudSettings.swift` — persisted preferences singleton. UserDefaults keys under `readAloud.*` (provider, appleVoiceIdentifier, elevenLabsVoiceId, elevenLabsModelId, openAIVoice, openAIModel, rate, pitch).
- `ReadAloudUsageTracker.swift` — spend/usage bookkeeping singleton. Records one `ReadAloudUsageRecord` per successful read (any provider, including free Apple) with provider / model / voice / character count / cached USD cost estimate. Cost is computed at write-time from `ReadAloudUsageTracker.estimatedCostUSD(...)` so historical rows stay stable if the pricing table changes. Records persisted as JSON blob in UserDefaults under `readAloud.usageHistory`; pruned to 5000 records / 365 days. Aggregation API: `costToday` / `costThisWeek` / `costThisMonth` / `lifetimeCost`, `breakdownByProvider(since:)`, `mostUsedVoice(since:)`, `projectedMonthlyCost` (linear projection), and `budgetProgress` / `isOverBudget` gated on `monthlyBudgetUSD` (stored in `readAloud.monthlyBudgetUSD`, 0 = disabled).
- `ReadAloudUsageWidget.swift` — reusable SwiftUI view for the usage tracker. Two styles: `.compact` (sidebar tile, tappable to jump to Read Aloud settings) and `.expanded` (full-width form section with per-provider bars + budget field). The compact tile lives in `AppSidebar` between the primary items and Settings so spend is always visible without opening the tab.
- `ReadAloudIndicatorWindow.swift` — floating 280×44 `NSPanel` at top-right (statusBar level, non-activating). Shows status, tortoise/hare speed buttons with rate display, pause/resume, stop, and a bottom progress bar.
- `ScreenRegionSelectionController.swift` — full-screen borderless `NSPanel` overlay per display, drag-to-select rectangle, dimmed veil with cutout, live dimensions label, then ScreenCaptureKit + Vision OCR on the drawn region. Escape / right-click cancels.
- Providers: Apple (local, free, uses downloadable premium voices) is default. ElevenLabs, OpenAI, and Gemini are cloud fallbacks — API keys stored via `APIKeyManager` under provider ids `"elevenlabs"`, `"openai"`, and `"gemini"` (Gemini key is shared with transcription / AI cleanup).
- Shortcut actions: `.readSelectedText`, `.readScreenRegion`, `.stopReading` (all in `ShortcutAction.globalUtilityActions`).
- Settings UI: dedicated sidebar section `ViewType.readAloud` → `ReadAloudSettingsView`. Opens with an expanded **Usage & Budget** section (per-provider bars, monthly budget, recent reads) so the sidebar spend tile has somewhere useful to land. Voice picker for OpenAI auto-filters by model (tts-1 / tts-1-hd only support the 9 base voices; Ballad/Verse/Marin/Cedar are `gpt-4o-mini-tts`-only). ElevenLabs section links to `elevenlabs.io/app/voice-library` and provides a Quick Pick menu of preset voice IDs (Rachel, Adam, Bella, Antoni, Domi). Both cloud sections have a "Test" button that pings the provider's API to verify the key.
- Sidebar order (`ViewType.primaryItems` in `AppSidebar.swift`): Dashboard, Dictation Modes (raw value still `"Modes"` for navigation-notification compatibility, visible label overridden to `"Dictation Modes"`), Read Aloud, Transcribe, AI Models, Audio, Dictionary, History. Below the primary items sits the `ReadAloudUsageWidget` tile, then Settings in the secondary section.

## Key files & directories
- `VoiceInk/VoiceInk.swift` — `@main` app entry + all first-launch seeders.
- `Makefile` — the whole build system (`local` / `dev` / `build` / `whisper` / `clean`).
- `LocalBuild.xcconfig` — ad-hoc signing overrides + `LOCAL_BUILD` compile flag for `make local`.
- `VoiceInk/VoiceInk.local.entitlements` — stripped entitlements (no CloudKit/keychain) for local builds.
- `VoiceInk/Modes/` — modes, ModeManager, ModeRuntimeConfiguration, language/style managers, triggers.
- `VoiceInk/Shortcuts/` — shortcut system, ShortcutMonitor, FnDoubleTapMonitor, ShortcutMigration/Validator.
- `VoiceInk/Transcription/` — STT engines: `FluidAudio/` + `Streaming/` (Parakeet), `Whisper/`, `Engine/` (VoiceInkEngine, TranscriptionPipeline).
- `VoiceInk/ReadAloud/` — text-to-speech feature: `ReadAloudManager`, `TextToSpeechService` (Apple), `CloudTTSProvider` (ElevenLabs + OpenAI), `ReadAloudSettings`, `ReadAloudIndicatorWindow`, `ScreenRegionSelectionController`.
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
- Read Aloud Gemini long-form limit: Google’s 3.1 Flash SSE streaming can truncate around ~60s of audio (`finishReason: OTHER`). Our player falls back to batch `generateContent` when streaming errors; for very long reads prefer shorter selections or accept batch wait. This is a provider limit, not an app crash.
- Read Aloud MainActor crash (2026-07-10): byte-at-a-time PCM streaming on MainActor (Gemini, and the same pattern in ElevenLabs) corrupted executor checks on macOS 26. Fixed by `AsyncStream<Data>` chunks off MainActor in `CloudTTSProvider.swift`. Do not reintroduce per-byte MainActor streaming.
- Dictation speed tips: keep **Real-time** on in the active mode; cycle style preset to **Raw** (or disable AI enhancement) to skip Ollama; use default paste (Cmd+V) not Direct Typing for long text; `KeepTranscriptionModelLoaded` (default on, AI Models → Advanced) avoids unloading Parakeet/Whisper after every session; `RecordingContextCaptureService` only runs clipboard/selection/screen probes the active mode actually uses for enhancement (screen OCR is expensive — don't enable unless needed).
- Read Aloud pricing table: `ReadAloudUsageTracker.estimatedCostUSD(...)` hardcodes provider rates as of 2026-07 (ElevenLabs $0.05/$0.10 per 1K chars, OpenAI $0.015/$0.030 per 1K chars). When providers update pricing, update this method AND the human-readable string in `pricingReference` AND the footer text in `ReadAloudSettingsView.usageSection`. Historical records aren't recomputed — cost is cached on each `ReadAloudUsageRecord` at write-time so past estimates stay stable.
- Read Aloud usage is only recorded after a *successful* HTTP 2xx response from cloud providers. Failed / cancelled / rate-limited requests don't count toward the spend estimate. Apple (local) reads are recorded with cost=$0 so "reads today" and "most used voice" stats cover local usage too.
- AI cleanup is minimal by default: `AIPrompts.enhancementSystemTemplate` + the Default (Clean) prompt keep the user's exact words and only strip fillers / fix grammar / punctuation / spelling. Style presets Email / Casual / Script Notes still request stronger transforms. Migration flag `hasMigratedMinimalCleanupPrompt_v1` overwrites the seeded Default prompt on existing installs.
- AI cleanup preamble stripping: small local LLMs (esp. `gemma3:4b`) tend to prefix their output with "Okay, here's the polished text:" even when the prompt forbids it. `AIEnhancementOutputFilter.filter(...)` runs regex-based preamble stripping (case-insensitive, anchored to `^`) as a defensive layer AFTER the `<thinking>` / `<reasoning>` scrubbing, so leaks that get past the prompt are cleaned before the text reaches paste/display.
- `PasteMethod.type` (Direct Typing, no clipboard): synthesizes text via `CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: ...)` with `keyboardSetUnicodeString(...)` in ~20-char UTF-16 chunks separated by 4ms sleeps. Bypasses `NSPasteboard` entirely — clipboard managers never see the transcript. `CursorPaster.performPasteSession` checks `method.usesClipboard` and short-circuits the clipboard snapshot / restore path when the user picks Direct Typing. Slower than Cmd+V on very long text (~200 chars/sec) but preserves the clipboard state, so it's the recommended choice for anyone using a clipboard-history tool.

## Git
- Remote: `brovzar-lab/Speakeasy-Voice`. This is the owner's personal fork; committing to `main` and pushing is fine. Do not force-push.

## Execute backlog workflow
- When Billy says “execute backlog,” read every pending entry in `BACKLOG.md`, choose the safest logical implementation order, and execute the full pending backlog without asking him to select items one by one.
- Work through entries sequentially so each change can be tested independently. Continue automatically unless an entry is destructive, irreversible, requires spending money, conflicts with another entry, or is genuinely blocked.
- Test each entry and show proof that it works.
- Move each entry from Pending to Completed only after its proof succeeds. Preserve its backlog UUID and add the completion date.

## Reference
- Original research and roadmap: `~/whisperflow-local-clone-plan.md`
