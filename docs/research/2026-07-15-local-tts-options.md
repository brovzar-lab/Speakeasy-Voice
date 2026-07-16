# Local and low-cost TTS options for Speakeasy-Voice

Date: 2026-07-15

## Bottom line

There is a credible way to make Speakeasy's Read Aloud feature essentially free to use on this Mac, and the local benchmark is complete.

**Kokoro-82M through MLX Audio Swift 0.1.3 is the production choice.** It is Apache-2.0 licensed, about 361 MB, supports native English and Spanish in the pinned Swift package, and reached first English audio in 0.74 seconds after warm-up. It generated 9.12 seconds of speech at 12.33 times real time while using about 312 MB of active memory.

Qwen3-TTS 0.6B was also proven locally but rejected for this interaction path. It took 3.64 seconds to first audio, used roughly 2.5 GB, and generated an 8-second sample in 5.53 seconds. Kokoro passed the speed and footprint gate, so MeloTTS was not needed as another production dependency.

If no local voice is pleasant enough for hours of listening, **buying Speechify is economically rational**. Its current consumer Premium price is $29 per month, and its 2026 terms guarantee up to 1,000,000 Premium Voice words per month. At Gemini's current paid output price, $29 is reached after only about 16 hours of generated speech. Billy's reported $9 in a few days is already on a much more expensive trajectory.

The implemented product strategy is therefore:

1. Fix the shared PCM audio-player crash.
2. Add Kokoro as the default Local HD voice.
3. Keep Apple as the free emergency fallback.
4. Make every paid fallback opt-in and enforce a hard monthly cap.
5. Keep Speechify as the honest alternative if the local listening quality is not good enough.

## Important crash finding

The July 15 crash happened while Gemini was selected, but the supplied crash report points to a **local audio graph failure**, not a Gemini HTTP error:

- exception: `EXC_BAD_ACCESS (SIGSEGV)`
- Apple framework: `AVFAudio`
- failing operation: `AVAudioEngine connect:to:format:`
- Speakeasy frame: `CloudTTSPlayer.setupPCMEngine`
- caller: `GeminiTTSProvider.speakWithBatch`

Source: `/Users/quantumcode/.codex/attachments/f5f7351a-8d41-41e1-9cef-d63bf74f92ce/pasted-text.txt`

Changing providers can avoid Gemini's API instability and cost, but it will not automatically fix this crash if the new local engine feeds PCM through the same unsafe player setup. The audio graph should be made serial and idempotent before adding another PCM provider.

## Current economics

### What the existing providers cost

| Service | Official unit price | Useful interpretation |
|---|---:|---:|
| Gemini 3.1 Flash TTS Preview, standard | $20 per 1M audio tokens | Google defines audio as 25 tokens/second, so this is **$1.80 per generated hour** |
| Gemini 3.1 Flash TTS Preview, batch | $10 per 1M audio tokens | **$0.90 per generated hour**, but batch is not suitable for instant interactive reading |
| ElevenLabs Flash/Turbo | $0.05 per 1K characters | $50 per 1M characters; ElevenLabs also estimates about **$0.05/minute** |
| ElevenLabs Multilingual v2/v3 | $0.10 per 1K characters | $100 per 1M characters |
| OpenAI GPT-4o mini TTS | $0.60 per 1M input text tokens plus $12 per 1M output audio tokens | Metered continuously; the official model page does not publish an audio-token-per-second conversion |

Sources: [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing), [ElevenLabs API pricing](https://elevenlabs.io/pricing/api?price.platform=api), and [OpenAI GPT-4o mini TTS](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts).

Derived from Google's published rate, $9 of Gemini 3.1 standard TTS is approximately five hours of generated speech. If that use occurred in two to three days, the simple 30-day projection is roughly $90 to $135. That projection assumes similar use and excludes the small text-input charge.

### Speechify comparison

Speechify's official consumer page currently lists Premium at **$29/month**, with 1,000+ voices, 60+ languages, and playback up to 5x. Its January 2026 Usage Limits page guarantees Premium users up to **1,000,000 Premium Voice words per month during 2026**, with a contractual baseline of at least 150,000 words per month. The terms prohibit account sharing, automation abuse, and commercial distribution without permission.

Sources: [Speechify pricing](https://speechify.com/pricing/), [Speechify 2026 usage limits](https://speechify.com/usage-limits/), and [Speechify terms](https://speechify.com/terms/).

At published prices, Speechify's $29 monthly charge is reached after approximately:

- 16.1 hours of Gemini 3.1 Flash TTS standard output at $1.80/hour.
- 9.7 hours of ElevenLabs Flash at ElevenLabs' own approximate $0.05/minute estimate.

This is not an argument against owning Speakeasy. Dictation, privacy, custom shortcuts, and the in-app backlog still have value. It means Speakeasy's paid-by-use cloud voices should not be the default for long-form personal reading.

## Local model comparison

| Candidate | English and Spanish | Size and hardware | macOS/Swift path | License | Assessment |
|---|---|---|---|---|---|
| **Qwen3-TTS 0.6B** | Yes, among 10 official languages | 8-bit MLX repository is 1.99 GB on disk; 0.6B parameters | Direct Swift Package exists for MLX on Apple Silicon and exposes streaming generation | Apache-2.0 model; MIT Swift runtime | **Best first HD-local candidate** |
| **Kokoro-82M** | Yes upstream | 363 MB upstream model; 82M parameters | sherpa-onnx has Swift/macOS and Kokoro support, but its packaged multilingual Kokoro currently warns that only English and Chinese are wired; MLX-Audio Python supports Spanish | Apache-2.0 | **Best lightweight English candidate; Spanish integration needs proof** |
| **MeloTTS** | Yes, dedicated English and Spanish models | Spanish checkpoint is about 208 MB; CPU real-time claimed by its model card | Python/PyTorch is ready; sherpa-onnx has Swift TTS and a MeloTTS iOS example, but a ready Spanish Swift package is not documented | MIT | **Good lightweight Spanish experiment** |
| **Chatterbox Multilingual V3** | Yes, 23 languages | 500M parameters; official ONNX browser demo is about 1.5 GB | PyTorch/MPS works with a Mac-specific patch; MLX-Audio Python has a port; no documented native Swift Chatterbox model | MIT | **Promising quality/voice-cloning trial, heavier integration risk** |
| **CosyVoice 3 0.5B** | Yes, 9 languages | Model repository totals 9.75 GB because it includes multiple large runtime artifacts | Official path is Python 3.10/Conda; ONNX components exist, but no supported native Swift package | Apache-2.0 | **Technically strong, poor first fit for a native Mac app** |
| **Piper/VITS** | Yes, with separate voices | Typical medium Spanish voice is about 63 MB | Excellent native path through sherpa-onnx Swift/macOS | Current Piper engine is GPL-3.0; each voice has its own model-card license | **Very stable emergency offline fallback; likely below the desired voice quality** |

### 1. Qwen3-TTS 0.6B

Qwen is the strongest match between quality-oriented features and Speakeasy's native Apple Silicon architecture.

The official Qwen project says Qwen3-TTS:

- supports Chinese, English, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and Italian;
- supports streaming speech generation with end-to-end latency reported as low as 97 ms;
- offers 0.6B and 1.7B variants;
- is licensed under Apache-2.0;
- includes multilingual and long-speech consistency evaluations, including English and Spanish.

Sources: [Qwen3-TTS official repository](https://github.com/QwenLM/Qwen3-TTS), [Qwen 0.6B model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base), [Qwen 0.6B CustomVoice model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice), and [Qwen benchmark tables](https://github.com/QwenLM/Qwen3-TTS/blob/main/README.md).

The third-party but open-source `mlx-audio-swift` project provides a Swift Package for Apple Silicon, a `MLXAudioTTS` module, Qwen3-TTS support, and an async streaming API. Its published supported model is the 8-bit 0.6B Base conversion. The model repository totals 1.99 GB, including a 1.3 GB main weight file and tokenizer assets.

Sources: [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift), [8-bit MLX model files](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit/tree/main), and [MLX Audio license](https://github.com/Blaizzy/mlx-audio-swift/blob/main/LICENSE).

Practical cautions:

- The Swift package README currently recommends tracking its `main` branch. Speakeasy should pin a tested commit instead.
- The Swift package explicitly lists the Base 8-bit checkpoint. Base is best suited to voice cloning from a reference recording. Preset `CustomVoice` support should be proven in a spike rather than assumed.
- Model startup will be slower than Kokoro or MeloTTS. Keep it loaded while Read Aloud is enabled and expose an unload option.
- The reported 97 ms is an upstream best-case result, not a promise for the Swift port or this app. Measure cold and warm time-to-first-audio locally.

On Billy's M4 Max with 128 GB unified memory, hardware capacity is not a concern. The proof should focus on latency, audio continuity, and whether the English and Spanish voices remain pleasant for long sessions.

### 2. Kokoro-82M

Kokoro is an unusually small permissive model. The upstream repository is 363 MB and Apache-2.0 licensed. Its voice catalog includes English and Spanish, and MLX-Audio lists support for English, Spanish, French, Italian, Portuguese, Hindi, Japanese, and Chinese.

Sources: [Kokoro model card and files](https://huggingface.co/hexgrad/Kokoro-82M), [Kokoro Spanish voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md), and [MLX-Audio Kokoro documentation](https://github.com/Blaizzy/mlx-audio).

`sherpa-onnx` is attractive because it supports macOS arm64, Swift, offline TTS, chunk callbacks, and Kokoro. It would fit the current native app better than a Python helper process. However, sherpa's official Kokoro package currently states that its multilingual model only wires English and Chinese. A Spanish Kokoro path therefore needs either a different ONNX export/frontend or a small native port of the required phonemization.

Sources: [sherpa-onnx platform and language support](https://github.com/k2-fsa/sherpa-onnx), [sherpa Kokoro documentation](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html), and [sherpa Kokoro Swift changelog](https://github.com/k2-fsa/sherpa-onnx/blob/master/CHANGELOG.md).

Verdict: test Kokoro immediately for English. Do not promise Spanish in the native app until the export and phonemizer work in a small standalone Swift proof.

### 3. MeloTTS

MeloTTS officially supports American, British, Indian, Australian, and default English plus Spanish, French, Chinese, Japanese, and Korean. The project says CPU inference is real-time. The dedicated Spanish checkpoint is approximately 208 MB and is MIT licensed for commercial and non-commercial use.

Sources: [MeloTTS official repository](https://github.com/myshell-ai/MeloTTS), [MeloTTS Spanish model card](https://huggingface.co/myshell-ai/MeloTTS-Spanish), and [Spanish checkpoint size](https://huggingface.co/myshell-ai/MeloTTS-Spanish/blob/main/checkpoint.pth).

The ready implementation is Python/PyTorch. `sherpa-onnx` has Swift TTS APIs, an iOS MeloTTS example, and past fixes for MeloTTS sentence splitting and lexicons, but its current model catalog does not present the official Spanish Melo checkpoint as a ready Swift download. This makes Melo a medium-effort conversion/integration task.

MeloTTS is a good Spanish-specific experiment because it is small and deterministic. It has less voice variety and control than Qwen, Chatterbox, or Speechify.

### 4. Chatterbox Multilingual V3

Resemble AI describes Chatterbox Multilingual V3 as a 500M-parameter, MIT-licensed model supporting 23 languages, including English and Spanish. Its V3 model card specifically claims reduced hallucination, stronger speaker consistency, and better multilingual naturalness than its earlier releases. It also offers a dedicated Latin American Spanish fine-tune.

Source: [Resemble AI Chatterbox repository and model card](https://github.com/resemble-ai/chatterbox) and [Chatterbox Hugging Face model](https://huggingface.co/ResembleAI/chatterbox).

The official project is PyTorch-first. An official issue confirms MPS can work using the project's Mac-specific patch, while Resemble's official Transformers.js ONNX demo says the first model load is about 1.5 GB and longer text must be chunked. MLX-Audio Python also lists Chatterbox support, but the MLX Swift package does not currently list it.

Sources: [official Apple/MPS issue](https://github.com/resemble-ai/chatterbox/issues/275) and [official Transformers.js ONNX demo](https://github.com/resemble-ai/transformersjs-chatterbox-demo).

Verdict: include it in a listening comparison, but do not make it the first production integration.

### 5. CosyVoice 3

Alibaba's FunAudioLLM team publishes CosyVoice 3 0.5B under Apache-2.0. It supports English, Spanish, Chinese, Japanese, Korean, German, French, Italian, and Russian, plus streaming input/output with latency reported as low as 150 ms. It also supports zero-shot voice cloning and delivery instructions.

Sources: [CosyVoice official repository](https://github.com/FunAudioLLM/CosyVoice), [CosyVoice 3 model card](https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512), and [Apache license file](https://github.com/FunAudioLLM/CosyVoice/blob/main/LICENSE).

The official installation is a Python 3.10 Conda environment with several large components. The current model repository totals 9.75 GB and includes PyTorch and ONNX variants. That is workable on Billy's Mac, but it is a poor fit for a compact native Swift application until a maintained MLX or Core ML port exists.

### 6. Piper through sherpa-onnx

Piper is fast, local, deterministic, and has many separate English and Spanish voices. A medium Spanish voice can be around 63 MB. `sherpa-onnx` already supports macOS arm64, Swift, Piper conversion, streaming callbacks, and offline playback.

Sources: [current Piper repository](https://github.com/OHF-Voice/piper1-gpl), [sherpa Piper integration](https://k2-fsa.github.io/sherpa/onnx/tts/piper.html), [sherpa TTS model catalog](https://k2-fsa.github.io/sherpa/onnx/tts/all/), and [example Spanish voice files](https://huggingface.co/rhasspy/piper-voices/tree/main/es/es_ES/davefx/medium).

The current Piper engine is GPL-3.0. Voice licenses vary, and Piper explicitly instructs users to inspect each voice's `MODEL_CARD`. Speakeasy is already GPLv3, but every selected voice still needs its license and attribution reviewed before bundling.

Piper is the safest technical fallback if the goal is simply “always speak without spending.” It is unlikely to match Speechify's most natural voices.

## Chinese/open projects that should not be integrated first

### Fish Speech

Fish Speech S2-Pro is technically capable, with 50+ languages and a 4B slow model plus 400M fast model. Its published low-latency benchmark uses an NVIDIA H200, not Apple Silicon. More importantly, its current Fish Audio Research License permits research and personal non-commercial use but requires a separate written license for commercial use, including a business's internal operations or distribution in a product.

Sources: [Fish Speech release](https://github.com/fishaudio/fish-speech/releases) and [Fish Audio Research License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE).

It is oversized for this need and creates avoidable licensing risk for a Lemon Studios owner's tool. Do not integrate it.

### ChatTTS

ChatTTS is trained for Chinese and English, not Spanish. Its code is AGPLv3 and its released model is CC BY-NC 4.0 for academic use. The project also says the released audio was intentionally quality-limited with high-frequency noise and MP3 compression.

Source: [ChatTTS official repository](https://github.com/2noise/ChatTTS).

It does not meet the language, license, or quality requirements.

## Lower-cost cloud fallbacks

If local quality is rejected, a conventional cloud TTS provider can cost much less than Gemini or ElevenLabs.

| Provider | English/Spanish | Official price | Relative to ElevenLabs Flash at $50/M characters |
|---|---|---:|---:|
| Google Cloud Standard | Yes | $4 per 1M characters after 4M free monthly characters | 92% lower |
| Google Cloud Neural2 | Yes | $16 per 1M characters after 1M free monthly characters | 68% lower |
| Google Cloud Chirp 3 HD | Yes | $30 per 1M characters after 1M free monthly characters | 40% lower |
| Amazon Polly Standard | Yes | $4 per 1M characters | 92% lower |
| Amazon Polly Neural | Yes | $16 per 1M characters | 68% lower |
| Amazon Polly Generative | Yes | $30 per 1M characters | 40% lower |
| Deepgram Aura-1 | Mainly English | $15 per 1M characters | 70% lower |
| Deepgram Aura-2 | English and Spanish, including Mexican voices | $30 per 1M characters | 40% lower |

Sources: [Google Cloud TTS pricing](https://cloud.google.com/text-to-speech/pricing), [Amazon Polly pricing](https://aws.amazon.com/polly/pricing/), [Amazon Polly voices](https://docs.aws.amazon.com/polly/latest/dg/available-voices.html), [Deepgram pricing](https://deepgram.com/pricing), and [Deepgram English/Spanish voices](https://developers.deepgram.com/docs/tts-models).

Amazon's official examples equate one million characters to roughly 23 hours and 8 minutes of speech. On that assumption:

- $4/M characters is about $0.17/hour.
- $16/M characters is about $0.69/hour.
- $30/M characters is about $1.30/hour.

Google Cloud and Amazon are cheaper but require new cloud credentials. Deepgram has the simplest token-style HTTP integration and good Mexican Spanish choices, but Aura-2 is not dramatically cheaper than Speechify at high monthly use.

Recommended paid fallback order if one is still desired:

1. Google Cloud Neural2 or Standard after a voice listening test.
2. Amazon Polly Neural if its available voices are preferred.
3. Deepgram Aura-2 for simpler streaming integration and Mexican Spanish.

No paid provider should activate silently after a local failure.

## Recommended Speakeasy architecture

### Provider policy

Use this order in the UI:

1. **Local HD, Kokoro-82M**: default after its one-time model download.
2. **Apple System**: free emergency fallback.
3. **Cloud providers**: metered, explicitly selected, and protected by a hard monthly limit.

The provider selector should show `Local • Free`, `Cloud • Metered`, and the estimated price beside every cloud model.

### Model lifecycle

- Download optional models to Application Support rather than adding 2 GB to the app bundle.
- Show download size before download and verify files against a pinned manifest/hash.
- Keep the selected local model warm while Read Aloud is enabled.
- Add a “Free memory” and “Delete model” control.
- Pin the exact MLX runtime commit and model revision. Do not track a moving `main` branch in production.

### Audio safety

- Own `AVAudioEngine` in one actor or serial queue.
- Create and connect the PCM graph once per playback session, not once per paragraph.
- Do not mutate or reconnect the graph from overlapping provider tasks.
- Validate sample rate, channel count, and common format before connecting nodes.
- Cancel generation first, drain scheduled buffers second, and tear down the graph last.
- Keep local inference off the main actor.
- Reuse the existing long-text segment planner and two-section prefetch, while feeding one continuous player session.

### Budget safety

- Default automatic paid fallback to **off**.
- Add a hard monthly budget, not merely a warning.
- Stop before making the request that would exceed the remaining budget.
- Warn at 50%, 80%, and 100%.
- Show actual provider usage separately from Speakeasy's local estimate when the response exposes it.
- Cache generated audio by model, voice, rate, and normalized text so rereading unchanged text costs nothing.

## Proof plan before production integration

Run a standalone local bake-off before adding a provider to the main app.

### Models to test

1. Qwen3-TTS 0.6B 8-bit through MLX.
2. Kokoro-82M.
3. MeloTTS English and Spanish.
4. Chatterbox Multilingual V3 only if the first three do not pass the listening test.

### Test material

- 150-character English email.
- 150-character Mexican Spanish WhatsApp message.
- 2,000-character English article.
- 2,000-character Spanish article.
- 20,000-character mixed long page with headings, lists, numbers, names, and paragraph breaks.
- The owner's proper nouns and recurring film vocabulary.

### Measurements

- cold model-load time;
- warm time to first audible PCM;
- real-time factor, where below 1.0 means generation is faster than playback;
- peak memory;
- audible gap between rolling sections;
- pronunciation failures in English and Spanish;
- repetitions, hallucinated words, missing endings, and truncations;
- pause, resume, seek, speed change, interrupt, and stop behavior;
- 100 consecutive reads and 20 rapid interrupt/restart cycles without a crash.

### Decision gate

Billy should blind-listen to at least two voices per viable model and compare them with his preferred Speechify voice. Ship local HD only if:

- both English and Spanish are comfortable for a 20-minute listen;
- warm playback starts within one second;
- long-form playback has no obvious paragraph gaps;
- the stress test has zero crashes and zero repeated sections.

If Qwen fails the quality gate, testing more infrastructure is not automatically the right answer. At the current use level, Speechify Premium may be the cheaper and more reliable product while Speakeasy remains the preferred dictation tool.

## Recommended implementation order

1. Repair and stress-test the shared PCM player using the July 15 crash as the regression case. Completed.
2. Benchmark Qwen and Kokoro locally and pin the winning runtime. Completed.
3. Add downloadable `Local HD` with continuous long-text playback. Completed with Kokoro.
4. Add hard budget enforcement and prevent invented paid fallbacks. Completed.
5. Only consider Google Cloud, Polly, or Deepgram later if Billy rejects the local listening quality.
