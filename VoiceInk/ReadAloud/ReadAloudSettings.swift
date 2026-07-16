import Foundation
import Combine

/// Which TTS provider handles read-aloud playback.
enum ReadAloudProvider: String, CaseIterable, Identifiable {
    case local
    case apple
    case elevenlabs
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:      return String(localized: "Local HD (Free)")
        case .apple:      return String(localized: "Apple (Local)")
        case .elevenlabs: return String(localized: "ElevenLabs")
        case .openai:     return String(localized: "OpenAI TTS")
        case .gemini:     return String(localized: "Gemini TTS")
        }
    }

    var shortName: String {
        switch self {
        case .local: return "Local HD"
        case .apple: return "Apple"
        case .elevenlabs: return "ElevenLabs"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var isMetered: Bool {
        switch self {
        case .local, .apple: return false
        case .elevenlabs, .openai, .gemini: return true
        }
    }
}

enum ReadAloudSelectionAction: Equatable {
    case start
    case replaceCurrent
    case enqueue
}

enum ReadAloudSelectionPolicy {
    static let defaultActionWhileActive: ReadAloudSelectionAction = .replaceCurrent

    static func action(
        isReading: Bool,
        enqueueSelectedText: Bool
    ) -> ReadAloudSelectionAction {
        guard isReading else { return .start }
        return enqueueSelectedText ? .enqueue : .replaceCurrent
    }
}

enum ReadAloudFallbackPolicy {
    static func resolve(
        primary: ReadAloudProvider,
        preferred: ReadAloudProvider,
        isEnabled: Bool,
        configuredProviders: Set<ReadAloudProvider>,
        error: CloudTTSError
    ) -> ReadAloudProvider? {
        guard isEnabled, error.isTransient, isSafeToRestart(after: error) else { return nil }

        // Only the explicitly selected backup may be metered. Any additional
        // automatic choices stay local so a provider outage cannot create an
        // unexpected bill on a different cloud account.
        var candidates = [preferred, .local, .apple]
        var seen = Set<ReadAloudProvider>()
        candidates = candidates.filter { seen.insert($0).inserted }
        return candidates.first { $0 != primary && configuredProviders.contains($0) }
    }

    private static func isSafeToRestart(after error: CloudTTSError) -> Bool {
        if case .streamEndedEarly = error { return false }
        return true
    }
}

enum ReadAloudPlaybackRecovery {
    static func run(
        primary: ReadAloudProvider,
        preferredFallback: ReadAloudProvider,
        fallbackEnabled: Bool,
        configuredProviders: Set<ReadAloudProvider>,
        onFallback: @MainActor (ReadAloudProvider, Error) -> Void,
        speak: (ReadAloudProvider) async throws -> Void
    ) async throws -> ReadAloudProvider {
        do {
            try await speak(primary)
            return primary
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudTTSError {
            guard let fallback = ReadAloudFallbackPolicy.resolve(
                primary: primary,
                preferred: preferredFallback,
                isEnabled: fallbackEnabled,
                configuredProviders: configuredProviders,
                error: error
            ) else {
                throw error
            }
            try Task.checkCancellation()
            await onFallback(fallback, error)
            try await speak(fallback)
            return fallback
        }
    }

    static func runSegmentAware(
        primary: ReadAloudProvider,
        preferredFallback: ReadAloudProvider,
        fallbackEnabled: Bool,
        configuredProviders: Set<ReadAloudProvider>,
        segmentCount: Int,
        onFallback: @MainActor (ReadAloudProvider, Error) -> Void,
        speak: (ReadAloudProvider, Int) async throws -> Void
    ) async throws -> ReadAloudProvider {
        do {
            try await speak(primary, 0)
            return primary
        } catch is CancellationError {
            throw CancellationError()
        } catch let partial as RollingTTSFailure {
            guard partial.firstSafeFallbackIndex < segmentCount,
                  let fallback = partialFallback(
                      primary: primary,
                      preferred: preferredFallback,
                      isEnabled: fallbackEnabled,
                      configuredProviders: configuredProviders,
                      error: partial.underlying
                  ) else {
                throw partial.underlying
            }
            try Task.checkCancellation()
            await onFallback(fallback, partial.underlying)
            try await speak(fallback, partial.firstSafeFallbackIndex)
            return fallback
        } catch let error as CloudTTSError {
            guard let fallback = ReadAloudFallbackPolicy.resolve(
                primary: primary,
                preferred: preferredFallback,
                isEnabled: fallbackEnabled,
                configuredProviders: configuredProviders,
                error: error
            ) else {
                throw error
            }
            try Task.checkCancellation()
            await onFallback(fallback, error)
            try await speak(fallback, 0)
            return fallback
        } catch let error as PaidTTSBudgetError {
            guard fallbackEnabled,
                  let fallback = [ReadAloudProvider.local, .apple]
                    .first(where: { $0 != primary && configuredProviders.contains($0) }) else {
                throw error
            }
            try Task.checkCancellation()
            await onFallback(fallback, error)
            try await speak(fallback, 0)
            return fallback
        } catch let error as LocalTTSError {
            guard fallbackEnabled,
                  primary == .local,
                  configuredProviders.contains(.apple) else {
                throw error
            }
            try Task.checkCancellation()
            await onFallback(.apple, error)
            try await speak(.apple, 0)
            return .apple
        }
    }

    private static func partialFallback(
        primary: ReadAloudProvider,
        preferred: ReadAloudProvider,
        isEnabled: Bool,
        configuredProviders: Set<ReadAloudProvider>,
        error: CloudTTSError
    ) -> ReadAloudProvider? {
        guard isEnabled, error.isTransient || error == .streamEndedEarly else { return nil }
        var seen = Set<ReadAloudProvider>()
        return [preferred, .local, .apple]
            .filter { seen.insert($0).inserted }
            .first { $0 != primary && configuredProviders.contains($0) }
    }
}

enum ReadAloudErrorPresentation {
    static func message(provider: ReadAloudProvider, error: Error) -> String {
        guard let cloudError = error as? CloudTTSError else {
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription,
               !description.isEmpty {
                return description
            }
            return "\(provider.shortName) could not read this selection. Please try again."
        }

        switch cloudError {
        case .httpError(let code, _) where code == 408 || code == 429 || (500...599).contains(code):
            return "\(provider.shortName) is temporarily unavailable. Please try again."
        case .streamEndedEarly:
            return "\(provider.shortName) stopped before finishing. Try a shorter selection."
        case .missingAPIKey:
            return "\(provider.shortName) needs an API key in Read Aloud settings."
        default:
            return "\(provider.shortName) could not read this selection. Please try again."
        }
    }
}

struct ReadAloudTextQueue {
    private var items: [String] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    mutating func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
    }

    mutating func dequeue() -> String? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    mutating func clear() {
        items.removeAll()
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
        static let localVoice = "readAloud.localVoice"
        static let appleVoiceIdentifier = "readAloud.appleVoiceIdentifier"
        static let elevenLabsVoiceId = "readAloud.elevenLabsVoiceId"
        static let elevenLabsModelId = "readAloud.elevenLabsModelId"
        static let openAIVoice = "readAloud.openAIVoice"
        static let openAIModel = "readAloud.openAIModel"
        static let geminiVoice = "readAloud.geminiVoice"
        static let geminiModel = "readAloud.geminiModel"
        static let rate = "readAloud.rate"
        static let pitch = "readAloud.pitch"
        static let automaticFallbackEnabled = "readAloud.automaticFallbackEnabled"
        static let fallbackProvider = "readAloud.fallbackProvider"
        static let enqueueSelectedText = "readAloud.enqueueSelectedText"
        static let migratedInterruptOnNewSelection = "readAloud.migratedInterruptOnNewSelection_v1"
        static let migratedLocalDefault = "readAloud.migratedLocalKokoroDefault_v1"
        static let migratedLocalFallback = "readAloud.migratedLocalKokoroFallback_v1"
    }

    @Published var provider: ReadAloudProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var localVoice: String {
        didSet { UserDefaults.standard.set(localVoice, forKey: Keys.localVoice) }
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

    @Published var automaticFallbackEnabled: Bool {
        didSet { UserDefaults.standard.set(automaticFallbackEnabled, forKey: Keys.automaticFallbackEnabled) }
    }

    @Published var fallbackProvider: ReadAloudProvider {
        didSet { UserDefaults.standard.set(fallbackProvider.rawValue, forKey: Keys.fallbackProvider) }
    }

    @Published var enqueueSelectedText: Bool {
        didSet { UserDefaults.standard.set(enqueueSelectedText, forKey: Keys.enqueueSelectedText) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Keys.migratedLocalDefault) {
            defaults.set(ReadAloudProvider.local.rawValue, forKey: Keys.provider)
            defaults.set(true, forKey: Keys.migratedLocalDefault)
        }
        self.provider = ReadAloudProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .local
        self.localVoice = defaults.string(forKey: Keys.localVoice) ?? "am_michael"
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
        self.automaticFallbackEnabled = defaults.bool(forKey: Keys.automaticFallbackEnabled)
        if !defaults.bool(forKey: Keys.migratedLocalFallback) {
            defaults.set(ReadAloudProvider.local.rawValue, forKey: Keys.fallbackProvider)
            defaults.set(true, forKey: Keys.migratedLocalFallback)
        }
        self.fallbackProvider = ReadAloudProvider(
            rawValue: defaults.string(forKey: Keys.fallbackProvider) ?? ""
        ) ?? .local
        if !defaults.bool(forKey: Keys.migratedInterruptOnNewSelection) {
            defaults.set(false, forKey: Keys.enqueueSelectedText)
            defaults.set(true, forKey: Keys.migratedInterruptOnNewSelection)
        }
        self.enqueueSelectedText = defaults.bool(forKey: Keys.enqueueSelectedText)
    }

    /// Build a `VoiceConfiguration` for the active provider.
    func makeVoiceConfiguration() -> VoiceConfiguration {
        makeVoiceConfiguration(for: provider)
    }

    func makeVoiceConfiguration(for provider: ReadAloudProvider) -> VoiceConfiguration {
        switch provider {
        case .local:
            return VoiceConfiguration(
                voiceIdentifier: localVoice,
                rate: rate,
                pitch: 1.0,
                volume: 1.0,
                languageCode: LocalKokoroVoices.languageCode(for: localVoice)
            )
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

    func modelIdentifier(for provider: ReadAloudProvider) -> String {
        switch provider {
        case .local: return LocalTTSModelManager.modelRepository
        case .apple: return "system"
        case .elevenlabs: return elevenLabsModelId
        case .openai: return openAIModel
        case .gemini: return geminiModel
        }
    }
}

enum LocalKokoroVoices {
    struct Voice: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    static let all: [Voice] = [
        Voice(id: "am_michael", displayName: "Michael (US English)"),
        Voice(id: "am_adam", displayName: "Adam (US English)"),
        Voice(id: "af_heart", displayName: "Heart (US English)"),
        Voice(id: "af_bella", displayName: "Bella (US English)"),
        Voice(id: "bm_george", displayName: "George (UK English)"),
        Voice(id: "bf_emma", displayName: "Emma (UK English)"),
        Voice(id: "ef_dora", displayName: "Dora (Spanish)"),
        Voice(id: "em_alex", displayName: "Alex (Spanish)"),
        Voice(id: "em_santa", displayName: "Santa (Spanish)")
    ]

    static func languageCode(for voice: String) -> String {
        switch voice.first {
        case "e": return "es"
        case "b": return "en-gb"
        default: return "en-us"
        }
    }
}
