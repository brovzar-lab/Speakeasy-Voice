import Foundation
import Combine

/// Which TTS provider handles read-aloud playback.
enum ReadAloudProvider: String, CaseIterable, Identifiable {
    case apple
    case elevenlabs
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:      return String(localized: "Apple (Local)")
        case .elevenlabs: return String(localized: "ElevenLabs")
        case .openai:     return String(localized: "OpenAI TTS")
        case .gemini:     return String(localized: "Gemini TTS")
        }
    }
}

/// User-configurable read-aloud preferences, persisted to `UserDefaults`.
///
/// The manager reads these each time a read starts so changes in the settings UI
/// take effect on the next playback without needing to restart anything.
@MainActor
final class ReadAloudSettings: ObservableObject {
    static let shared = ReadAloudSettings()

    private enum Keys {
        static let provider = "readAloud.provider"
        static let appleVoiceIdentifier = "readAloud.appleVoiceIdentifier"
        static let elevenLabsVoiceId = "readAloud.elevenLabsVoiceId"
        static let elevenLabsModelId = "readAloud.elevenLabsModelId"
        static let openAIVoice = "readAloud.openAIVoice"
        static let openAIModel = "readAloud.openAIModel"
        static let geminiVoice = "readAloud.geminiVoice"
        static let geminiModel = "readAloud.geminiModel"
        static let rate = "readAloud.rate"
        static let pitch = "readAloud.pitch"
    }

    @Published var provider: ReadAloudProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var appleVoiceIdentifier: String? {
        didSet {
            if let id = appleVoiceIdentifier {
                UserDefaults.standard.set(id, forKey: Keys.appleVoiceIdentifier)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.appleVoiceIdentifier)
            }
        }
    }

    @Published var elevenLabsVoiceId: String {
        didSet { UserDefaults.standard.set(elevenLabsVoiceId, forKey: Keys.elevenLabsVoiceId) }
    }

    @Published var elevenLabsModelId: String {
        didSet { UserDefaults.standard.set(elevenLabsModelId, forKey: Keys.elevenLabsModelId) }
    }

    @Published var openAIVoice: String {
        didSet { UserDefaults.standard.set(openAIVoice, forKey: Keys.openAIVoice) }
    }

    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel) }
    }

    @Published var geminiVoice: String {
        didSet { UserDefaults.standard.set(geminiVoice, forKey: Keys.geminiVoice) }
    }

    @Published var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: Keys.geminiModel) }
    }

    /// Playback rate. 1.0 = natural speed. Each provider clamps to its own range.
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(rate, forKey: Keys.rate) }
    }

    /// Pitch (Apple only). 1.0 = natural.
    @Published var pitch: Float {
        didSet { UserDefaults.standard.set(pitch, forKey: Keys.pitch) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.provider = ReadAloudProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .apple
        self.appleVoiceIdentifier = defaults.string(forKey: Keys.appleVoiceIdentifier)
        self.elevenLabsVoiceId = defaults.string(forKey: Keys.elevenLabsVoiceId) ?? "21m00Tcm4TlvDq8ikWAM" // "Rachel" default
        // Flash v2.5 is the recommended default: ~75ms latency (~3-4x faster than Turbo),
        // same $0.05 / 1K chars price. See ReadAloud settings UI for the model picker.
        var resolvedElevenLabsModel = defaults.string(forKey: Keys.elevenLabsModelId) ?? "eleven_flash_v2_5"
        if resolvedElevenLabsModel == "eleven_turbo_v2_5",
           !defaults.bool(forKey: "readAloud.migratedElevenLabsFlash_v1") {
            resolvedElevenLabsModel = "eleven_flash_v2_5"
            defaults.set(true, forKey: "readAloud.migratedElevenLabsFlash_v1")
        }
        self.elevenLabsModelId = resolvedElevenLabsModel
        self.openAIVoice = defaults.string(forKey: Keys.openAIVoice) ?? "nova"
        self.openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "tts-1"
        self.geminiVoice = defaults.string(forKey: Keys.geminiVoice) ?? "Kore"
        // 3.1 Flash streams audio (fast time-to-first-sound). Migrate prior 2.5
        // defaults once — 2.5 is still available in the picker for cheapest cost.
        var resolvedGeminiModel = defaults.string(forKey: Keys.geminiModel) ?? "gemini-3.1-flash-tts-preview"
        if resolvedGeminiModel == "gemini-2.5-flash-preview-tts",
           !defaults.bool(forKey: "readAloud.migratedGemini31Flash_v1") {
            resolvedGeminiModel = "gemini-3.1-flash-tts-preview"
            defaults.set(true, forKey: "readAloud.migratedGemini31Flash_v1")
        }
        self.geminiModel = resolvedGeminiModel
        let storedRate = defaults.object(forKey: Keys.rate) as? Float
        self.rate = storedRate ?? 1.0
        let storedPitch = defaults.object(forKey: Keys.pitch) as? Float
        self.pitch = storedPitch ?? 1.0
    }

    /// Build a `VoiceConfiguration` for the active provider.
    func makeVoiceConfiguration() -> VoiceConfiguration {
        switch provider {
        case .apple:
            return VoiceConfiguration(
                voiceIdentifier: appleVoiceIdentifier,
                rate: rate,
                pitch: pitch,
                volume: 1.0,
                languageCode: nil
            )
        case .elevenlabs:
            return VoiceConfiguration(
                voiceIdentifier: elevenLabsVoiceId,
                rate: rate,
                pitch: 1.0,
                volume: 1.0,
                languageCode: nil
            )
        case .openai:
            return VoiceConfiguration(
                voiceIdentifier: openAIVoice,
                rate: rate,
                pitch: 1.0,
                volume: 1.0,
                languageCode: nil
            )
        case .gemini:
            return VoiceConfiguration(
                voiceIdentifier: geminiVoice,
                rate: rate,
                pitch: 1.0,
                volume: 1.0,
                languageCode: nil
            )
        }
    }

    /// Whether the selected Gemini model supports `streamGenerateContent` audio.
    var geminiSupportsStreaming: Bool {
        geminiModel.contains("3.1")
    }
}
