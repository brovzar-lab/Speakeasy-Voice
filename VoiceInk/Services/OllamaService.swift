import Foundation
import SwiftUI
import LLMkit

class OllamaService: ObservableObject {
    static let defaultBaseURL = "http://localhost:11434"

    // MARK: - Published Properties
    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: "ollamaBaseURL")
        }
    }

    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "ollamaSelectedModel")
        }
    }

    @Published var availableModels: [OllamaModel] = []
    @Published var isConnected: Bool = false
    @Published var isLoadingModels: Bool = false

    private let defaultTemperature: Double = 0.3

    init() {
        self.baseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? Self.defaultBaseURL
        self.selectedModel = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "llama2"
    }

    private var baseURLValue: URL? {
        URL(string: baseURL)
    }

    @MainActor
    func checkConnection() async {
        guard let url = baseURLValue else {
            isConnected = false
            return
        }
        isConnected = await OllamaClient.checkConnection(baseURL: url)
    }

    @MainActor
    func refreshModels() async {
        _ = await refreshConnectionAndModels()
    }

    @MainActor
    func refreshConnectionAndModels() async -> Result<[OllamaModel], Error> {
        isLoadingModels = true
        defer { isLoadingModels = false }

        guard let url = baseURLValue else {
            isConnected = false
            availableModels = []
            return .failure(LocalAIError.invalidURL)
        }

        do {
            let models = try await OllamaClient.fetchModels(baseURL: url)
            isConnected = true
            availableModels = models

            if !models.contains(where: { $0.name == selectedModel }) && !models.isEmpty {
                selectedModel = models[0].name
            }

            return .success(models)
        } catch {
            isConnected = false
            availableModels = []
            return .failure(error)
        }
    }

    func enhance(_ text: String, withSystemPrompt systemPrompt: String? = nil, model: String? = nil, timeout: TimeInterval = 30) async throws -> String {
        guard let systemPrompt = systemPrompt else {
            throw LocalAIError.invalidRequest
        }

        guard let url = baseURLValue else {
            throw LocalAIError.invalidURL
        }

        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestModel = (trimmedModel?.isEmpty == false ? trimmedModel : nil) ?? selectedModel

        do {
            return try await OllamaClient.generate(
                baseURL: url,
                model: requestModel,
                prompt: text,
                systemPrompt: systemPrompt,
                temperature: defaultTemperature,
                think: false,
                timeout: timeout
            )
        } catch let error as LLMKitError {
            throw mapLLMKitError(error)
        }
    }

    /// Fire a tiny inference request to force Ollama to load the model into
    /// memory. Ollama unloads models after a keep-alive timeout (default 5min)
    /// — so on a cold launch, the very first real cleanup pays a 3-8 second
    /// model-load penalty. Warming eliminates that penalty for the first
    /// dictation of the session, which is when speed matters most.
    ///
    /// Uses a minimal 1-token prompt and short timeout. Failures are silent —
    /// if Ollama isn't running, transcription still works, we just don't warm.
    func warmupSelectedModel() async {
        guard let url = baseURLValue else { return }
        let modelName = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { return }

        do {
            _ = try await OllamaClient.generate(
                baseURL: url,
                model: modelName,
                prompt: ".",
                systemPrompt: "Respond with a single period.",
                temperature: 0,
                think: false,
                timeout: 30
            )
        } catch {
            // Cold-launch warmup is best-effort. Log and move on.
        }
    }

    private func mapLLMKitError(_ error: LLMKitError) -> LocalAIError {
        switch error {
        case .invalidURL:
            return .invalidURL
        case .httpError(let statusCode, _):
            if statusCode == 404 { return .modelNotFound }
            if statusCode == 500 { return .serverError }
            return .invalidResponse
        case .networkError:
            return .serviceUnavailable
        case .noResultReturned, .decodingError:
            return .invalidResponse
        case .encodingError:
            return .invalidRequest
        case .missingAPIKey:
            return .invalidResponse
        case .timeout:
            return .timeout
        }
    }
}

// MARK: - Error Types
enum LocalAIError: Error, LocalizedError {
    case invalidURL
    case serviceUnavailable
    case invalidResponse
    case modelNotFound
    case serverError
    case invalidRequest
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid Ollama server URL")
        case .serviceUnavailable:
            return String(localized: "Ollama service is not available")
        case .invalidResponse:
            return String(localized: "Invalid response from Ollama server")
        case .modelNotFound:
            return String(localized: "Selected model not found")
        case .serverError:
            return String(localized: "Ollama server error")
        case .invalidRequest:
            return String(localized: "System prompt is required")
        case .timeout:
            return String(localized: "Ollama request timed out")
        }
    }
}
