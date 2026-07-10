import SwiftUI

/// Settings surface for the Read Aloud feature.
///
/// Voice + provider selection lives here so the manager can stay a thin
/// orchestrator. Uses the same grouped `Form` style as `AudioSetupView`.
struct ReadAloudSettingsView: View {
    @ObservedObject private var settings = ReadAloudSettings.shared
    @ObservedObject private var manager = ReadAloudManager.shared

    @State private var voiceCatalog: AppleVoiceCatalog = .load()
    @State private var elevenLabsAPIKey: String = APIKeyManager.shared.getAPIKey(forProvider: "elevenlabs") ?? ""
    @State private var openAIAPIKey: String = APIKeyManager.shared.getAPIKey(forProvider: "openai") ?? ""
    @State private var sampleText: String = String(localized: "The quick brown fox jumps over the lazy dog. This is what the selected voice sounds like.")

    @State private var openAIKeyStatus: KeyStatus = .unknown
    @State private var elevenLabsKeyStatus: KeyStatus = .unknown

    enum KeyStatus {
        case unknown, testing, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(ReadAloudProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Rate") {
                    HStack {
                        Slider(value: $settings.rate, in: 0.5...2.0, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2fx", settings.rate))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Trigger read-aloud with the shortcuts on the Settings page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch settings.provider {
            case .apple:
                appleSection
            case .elevenlabs:
                elevenLabsSection
            case .openai:
                openAISection
            }

            Section {
                TextField("Sample Text", text: $sampleText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        manager.preview(text: trimmed)
                    } label: {
                        Label("Preview Voice", systemImage: "play.circle.fill")
                    }
                    .disabled(sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        manager.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(manager.state == .idle)
                }
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            voiceCatalog = AppleVoiceCatalog.load()
            elevenLabsAPIKey = APIKeyManager.shared.getAPIKey(forProvider: "elevenlabs") ?? ""
            openAIAPIKey = APIKeyManager.shared.getAPIKey(forProvider: "openai") ?? ""
            reconcileOpenAIVoice()
        }
        .onChange(of: settings.openAIModel) { _, _ in
            reconcileOpenAIVoice()
        }
    }

    // MARK: - Apple

    private var appleSection: some View {
        Section {
            Picker("Voice", selection: appleVoiceBinding) {
                Text("System Default").tag(String?.none)
                ForEach(voiceCatalog.entries) { entry in
                    Text("\(entry.name) — \(entry.language) (\(entry.qualityLabel))")
                        .tag(Optional(entry.id))
                }
            }
            .pickerStyle(.menu)

            LabeledContent("Pitch") {
                HStack {
                    Slider(value: $settings.pitch, in: 0.5...2.0, step: 0.05)
                        .frame(width: 200)
                    Text(String(format: "%.2fx", settings.pitch))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                    NSWorkspace.shared.open(url)
                }
                voiceCatalog = AppleVoiceCatalog.load()
            } label: {
                Label("Download More Voices…", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Apple Voice")
        } footer: {
            Text("Higher-quality voices can be downloaded from System Settings → Accessibility → Spoken Content.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appleVoiceBinding: Binding<String?> {
        Binding(
            get: { settings.appleVoiceIdentifier },
            set: { settings.appleVoiceIdentifier = $0 }
        )
    }

    // MARK: - ElevenLabs

    private var elevenLabsSection: some View {
        Section {
            HStack {
                SecureField("API Key", text: $elevenLabsAPIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    APIKeyManager.shared.saveAPIKey(elevenLabsAPIKey, forProvider: "elevenlabs")
                    elevenLabsKeyStatus = .unknown
                }
                .disabled(elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") {
                    Task { await testElevenLabsKey() }
                }
                .disabled(elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            keyStatusRow(elevenLabsKeyStatus)

            HStack {
                TextField("Voice ID", text: $settings.elevenLabsVoiceId)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if let url = URL(string: "https://elevenlabs.io/app/voice-library") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Voice Library", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .help("Open the ElevenLabs Voice Library")
            }

            Picker("Model", selection: $settings.elevenLabsModelId) {
                Text("Flash v2.5 (fastest — recommended)").tag("eleven_flash_v2_5")
                Text("Turbo v2.5 (balanced)").tag("eleven_turbo_v2_5")
                Text("Multilingual v2 (highest quality)").tag("eleven_multilingual_v2")
            }
            .pickerStyle(.menu)

            LabeledContent("Common Voices") {
                Menu("Quick Pick") {
                    Button("Rachel (default female)") { settings.elevenLabsVoiceId = "21m00Tcm4TlvDq8ikWAM" }
                    Button("Adam (male)") { settings.elevenLabsVoiceId = "pNInz6obpgDQGcFmaJgB" }
                    Button("Bella (female)") { settings.elevenLabsVoiceId = "EXAVITQu4vr4xnSDxMaL" }
                    Button("Antoni (male)") { settings.elevenLabsVoiceId = "ErXwobaYiN019PkySvjV" }
                    Button("Domi (female)") { settings.elevenLabsVoiceId = "AZnzlk1XvdvUeBnXmlld" }
                }
            }
        } header: {
            Text("ElevenLabs")
        } footer: {
            Text("Get your API key at elevenlabs.io → Settings → API Keys. Browse voices at elevenlabs.io → Voice Library, then click a voice's three-dot menu → Copy Voice ID. If a voice returns 'voice_not_found', add it to your library first by clicking 'Add to VoiceLab' on the voice page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - OpenAI

    private var openAISection: some View {
        Section {
            HStack {
                SecureField("API Key", text: $openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    APIKeyManager.shared.saveAPIKey(openAIAPIKey, forProvider: "openai")
                    openAIKeyStatus = .unknown
                }
                .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") {
                    Task { await testOpenAIKey() }
                }
                .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            keyStatusRow(openAIKeyStatus)

            Picker("Model", selection: $settings.openAIModel) {
                Text("tts-1 (fast)").tag("tts-1")
                Text("tts-1-hd (higher fidelity)").tag("tts-1-hd")
                Text("gpt-4o-mini-tts (steerable, all voices)").tag("gpt-4o-mini-tts")
            }
            .pickerStyle(.menu)

            Picker("Voice", selection: $settings.openAIVoice) {
                ForEach(OpenAITTSVoices.voices(for: settings.openAIModel)) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("OpenAI TTS")
        } footer: {
            Text("Only 9 voices are supported on tts-1 / tts-1-hd. Ballad, Verse, Marin, and Cedar are exclusive to gpt-4o-mini-tts. Make sure your API key has audio.speech scope enabled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// If the saved voice isn't compatible with the saved model, pick the first
    /// supported voice for that model. Prevents 400 errors from stale combos
    /// like "Ballad + tts-1-hd" carried over from earlier releases.
    private func reconcileOpenAIVoice() {
        let supported = OpenAITTSVoices.supportedVoiceIds(for: settings.openAIModel)
        if !supported.contains(settings.openAIVoice), let first = supported.first {
            settings.openAIVoice = first
        }
    }


    // MARK: - Key status

    @ViewBuilder
    private func keyStatusRow(_ status: KeyStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .ok:
            Label("API key works", systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func testOpenAIKey() async {
        openAIKeyStatus = .testing
        let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist so the test uses the same value the real path would.
        APIKeyManager.shared.saveAPIKey(key, forProvider: "openai")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                openAIKeyStatus = .failed(String(localized: "Unexpected response"))
                return
            }
            switch http.statusCode {
            case 200..<300:
                openAIKeyStatus = .ok
            case 401:
                openAIKeyStatus = .failed(String(localized: "401 Unauthorized — key is invalid or lacks permissions"))
            case 429:
                openAIKeyStatus = .failed(String(localized: "429 Rate limited — but the key is valid"))
            default:
                openAIKeyStatus = .failed(String(format: String(localized: "HTTP %d"), http.statusCode))
            }
        } catch {
            openAIKeyStatus = .failed(error.localizedDescription)
        }
    }

    private func testElevenLabsKey() async {
        elevenLabsKeyStatus = .testing
        let key = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        APIKeyManager.shared.saveAPIKey(key, forProvider: "elevenlabs")

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                elevenLabsKeyStatus = .failed(String(localized: "Unexpected response"))
                return
            }
            switch http.statusCode {
            case 200..<300:
                elevenLabsKeyStatus = .ok
            case 401:
                elevenLabsKeyStatus = .failed(String(localized: "401 Unauthorized — key is invalid or missing scopes"))
            default:
                elevenLabsKeyStatus = .failed(String(format: String(localized: "HTTP %d"), http.statusCode))
            }
        } catch {
            elevenLabsKeyStatus = .failed(error.localizedDescription)
        }
    }
}

// MARK: - OpenAI voice/model compatibility

/// Static catalog of OpenAI TTS voices with per-model availability.
///
/// `tts-1` and `tts-1-hd` support 9 voices; `gpt-4o-mini-tts` supports all 13.
/// Keeping this in one place so the voice picker can filter live as the model changes.
enum OpenAITTSVoices {
    struct Voice: Identifiable, Hashable {
        let id: String
        let displayName: String
        let onlyGPT4oMiniTTS: Bool
    }

    static let all: [Voice] = [
        Voice(id: "alloy",   displayName: "Alloy",   onlyGPT4oMiniTTS: false),
        Voice(id: "ash",     displayName: "Ash",     onlyGPT4oMiniTTS: false),
        Voice(id: "coral",   displayName: "Coral",   onlyGPT4oMiniTTS: false),
        Voice(id: "echo",    displayName: "Echo",    onlyGPT4oMiniTTS: false),
        Voice(id: "fable",   displayName: "Fable",   onlyGPT4oMiniTTS: false),
        Voice(id: "nova",    displayName: "Nova",    onlyGPT4oMiniTTS: false),
        Voice(id: "onyx",    displayName: "Onyx",    onlyGPT4oMiniTTS: false),
        Voice(id: "sage",    displayName: "Sage",    onlyGPT4oMiniTTS: false),
        Voice(id: "shimmer", displayName: "Shimmer", onlyGPT4oMiniTTS: false),
        Voice(id: "ballad",  displayName: "Ballad (gpt-4o-mini-tts only)", onlyGPT4oMiniTTS: true),
        Voice(id: "verse",   displayName: "Verse (gpt-4o-mini-tts only)",  onlyGPT4oMiniTTS: true),
        Voice(id: "marin",   displayName: "Marin (gpt-4o-mini-tts only)",  onlyGPT4oMiniTTS: true),
        Voice(id: "cedar",   displayName: "Cedar (gpt-4o-mini-tts only)",  onlyGPT4oMiniTTS: true)
    ]

    static func voices(for model: String) -> [Voice] {
        if model == "gpt-4o-mini-tts" {
            return all
        }
        return all.filter { !$0.onlyGPT4oMiniTTS }
    }

    static func supportedVoiceIds(for model: String) -> [String] {
        voices(for: model).map(\.id)
    }
}
