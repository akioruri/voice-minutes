import Foundation

/// A cloud vendor that can provide transcription, meeting summaries, or both.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case mistral
    case openAI
    case miniMax
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mistral:
            return "Mistral"
        case .openAI:
            return "OpenAI"
        case .miniMax:
            return "MiniMax"
        case .openAICompatible:
            return InterfaceLanguage.current.text("provider.openAICompatible")
        }
    }

    var defaultConfiguration: ProviderConfiguration {
        switch self {
        case .mistral:
            return ProviderConfiguration(
                baseURL: "https://api.mistral.ai/v1",
                transcriptionModel: "voxtral-mini-latest",
                summaryModel: "mistral-small-latest",
                apiKey: ""
            )
        case .openAI:
            return ProviderConfiguration(
                baseURL: "https://api.openai.com/v1",
                transcriptionModel: "whisper-1",
                summaryModel: "gpt-5.4-mini",
                apiKey: ""
            )
        case .miniMax:
            return ProviderConfiguration(
                baseURL: "https://api.minimax.io/v1",
                transcriptionModel: "asr-1.0",
                summaryModel: "MiniMax-M3.1-Flash",
                apiKey: ""
            )
        case .openAICompatible:
            return ProviderConfiguration(
                baseURL: "",
                transcriptionModel: "whisper-1",
                summaryModel: "gpt-5.4-mini",
                apiKey: ""
            )
        }
    }

    var maximumChunkDuration: TimeInterval {
        switch self {
        case .miniMax:
            // MiniMax ASR currently rejects audio longer than 500 seconds.
            return 8 * 60
        case .mistral, .openAI, .openAICompatible:
            return 15 * 60
        }
    }

    var maximumConcurrentRequests: Int {
        switch self {
        case .miniMax:
            return 2
        case .mistral, .openAI, .openAICompatible:
            return 3
        }
    }
}

struct ProviderConfiguration: Sendable {
    var baseURL: String
    var transcriptionModel: String
    var summaryModel: String
    var apiKey: String
}
