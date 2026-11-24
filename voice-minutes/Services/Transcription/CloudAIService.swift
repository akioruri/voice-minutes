import Foundation

/// Handles cloud transcription and Markdown summary requests for one provider.
struct CloudAIService: Sendable {
    let provider: AIProvider
    let configuration: ProviderConfiguration
    let promptTemplate: String
    /// AI responses follow the interface language.
    let responseLanguage: String

    init(
        provider: AIProvider,
        configuration: ProviderConfiguration,
        promptTemplate: String = AppSettings.defaultPrompt,
        responseLanguage: String = InterfaceLanguage.current.aiLanguageName
    ) {
        self.provider = provider
        self.configuration = configuration
        self.promptTemplate = promptTemplate
        self.responseLanguage = responseLanguage
    }

    func transcribe(fileURL: URL) async throws -> CloudTranscriptionResponse {
        guard !configuration.apiKey.isEmpty else {
            throw CloudAIError.missingAPIKey(provider.displayName)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        func appendField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        let model = configuration.transcriptionModel
        let usesSRTResponse = (
            provider == .openAI || provider == .openAICompatible
        ) && !model.lowercased().contains("whisper")

        appendField("model", model)

        switch provider {
        case .mistral:
            appendField("language", "zh")
            appendField("diarize", "false")
            appendField("timestamp_granularities", "segment")
        case .openAI, .openAICompatible:
            appendField("language", "zh")
            if usesSRTResponse {
                appendField("response_format", "srt")
            } else {
                appendField("response_format", "verbose_json")
                appendField("timestamp_granularities[]", "segment")
            }
        case .miniMax:
            appendField("response_format", "verbose_json")
            appendField("timestamp_level", "sentence")
            appendField("stream", "false")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let path = provider == .miniMax
            ? "speech_to_text"
            : "audio/transcriptions"
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if provider == .miniMax {
            request.setValue("zh", forHTTPHeaderField: "language")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        if usesSRTResponse,
           let rawSRT = String(data: data, encoding: .utf8) {
            let segments = CloudSRTParser.parse(rawSRT)
            if !segments.isEmpty {
                return CloudTranscriptionResponse(
                    model: model,
                    text: segments.map(\.text).joined(separator: "\n"),
                    language: "zh",
                    duration: nil,
                    segments: segments
                )
            }
        }

        do {
            let result = try JSONDecoder().decode(
                CloudTranscriptionResponse.self,
                from: data
            )
            guard hasTranscriptionContent(result) else {
                throw CloudAIError.emptyTranscription(
                    provider: provider.displayName,
                    model: model
                )
            }
            return result
        } catch let error as CloudAIError {
            throw error
        } catch {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return CloudTranscriptionResponse(
                    model: model,
                    text: text,
                    language: nil,
                    duration: nil,
                    segments: nil
                )
            }
            throw CloudAIError.invalidResponse(error.localizedDescription)
        }
    }

    func summarize(transcript: String, notes: String = "") async throws -> String {
        guard !configuration.apiKey.isEmpty else {
            throw CloudAIError.missingAPIKey(provider.displayName)
        }

        // Internal scaffolding is English by design; only user-visible
        // templates are localized.
        let systemPrompt = """
        You are a rigorous meeting-minutes assistant. Use only the transcript \
        content provided by the user. Never invent people, numbers, conclusions, \
        owners, or deadlines. Output only the final Markdown — no explanations, \
        preambles, or code fences. Preserve Markdown blank lines and list line \
        breaks so the result reads correctly.
        """

        let userPrompt = """
        Organize meeting minutes according to the following requirements:

        \(promptTemplate)

        --- TRANSCRIPT START ---
        \(transcript)
        --- TRANSCRIPT END ---
        """

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSection = trimmedNotes.isEmpty ? "" : """

        --- USER KEY NOTES START ---
        \(trimmedNotes)
        --- USER KEY NOTES END ---
        These are key points the user recorded manually during the meeting; \
        the minutes must prioritize them.
        """

        let userPromptWithNotes = userPrompt + notesSection

        return try await chat(systemPrompt: systemPrompt, userPrompt: userPromptWithNotes)
    }

    /// Explains one key-note block against the full transcript. The system
    /// prompt is the fixed product wording; the block text rides in the user
    /// message alongside the transcript.
    func analyzeKeyPoint(
        transcript: String,
        keyPoint: String,
        promptTemplate: String
    ) async throws -> String {
        guard !configuration.apiKey.isEmpty else {
            throw CloudAIError.missingAPIKey(provider.displayName)
        }

        let systemPrompt = promptTemplate

        let userPrompt = """
        --- TRANSCRIPT START ---
        \(transcript)
        --- TRANSCRIPT END ---

        --- KEY POINT START ---
        \(keyPoint)
        --- KEY POINT END ---

        Summarize and explain only the key point above, based on the transcript.
        Output only the final Markdown — no explanations, preambles, or code fences.
        """

        return try await chat(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    /// Generates a new minutes prompt by revising the built-in base template
    /// according to the user's description. The meta-prompt is English and
    /// never shown; the generated prompt follows the response language.
    /// Generates a revised minutes prompt from a description, returning both
    /// a short title and the body. The model emits the title on the first
    /// line, a blank line, then the prompt body.
    func generatePrompt(
        description: String,
        baseTemplate: String
    ) async throws -> (name: String, body: String) {
        guard !configuration.apiKey.isEmpty else {
            throw CloudAIError.missingAPIKey(provider.displayName)
        }

        let systemPrompt = """
        You are an expert prompt engineer for meeting-minutes assistants.
        Revise the base prompt template below so it satisfies the user's description.
        Preserve the template's overall structure and output-format requirements \
        unless the description explicitly asks to change them.
        Output exactly two parts: the FIRST line is a short, descriptive title \
        for the prompt (at most 12 characters, no quotes or prefixes); after a \
        blank line, output the revised prompt body. Output nothing else — no \
        explanations, no code fences.
        """

        let userPrompt = """
        --- BASE TEMPLATE START ---
        \(baseTemplate)
        --- BASE TEMPLATE END ---

        --- USER DESCRIPTION START ---
        \(description)
        --- USER DESCRIPTION END ---
        """

        let raw = try await chat(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return Self.splitTitleAndBody(raw)
    }

    /// Splits generated prompt text into its first non-empty line (title) and
    /// the remaining lines (body).
    static func splitTitleAndBody(_ raw: String) -> (name: String, body: String) {
        let lines = raw.components(separatedBy: .newlines)
        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return ("", raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let name = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        let body = lines[(titleIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, body)
    }

    /// Shared chat/completions round trip for summary and key-point analysis.
    private func chat(systemPrompt: String, userPrompt: String) async throws -> String {
        let localizedSystem = systemPrompt
            + "\n\nAlways write your response in \(responseLanguage)."
        let payload = ChatCompletionRequest(
            model: configuration.summaryModel,
            messages: [
                ChatMessage(role: "system", content: localizedSystem),
                ChatMessage(role: "user", content: userPrompt)
            ]
        )

        var request = URLRequest(url: try endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        do {
            let result = try JSONDecoder().decode(
                ChatCompletionResponse.self,
                from: data
            )
            guard let content = result.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw CloudAIError.invalidResponse(
                    InterfaceLanguage.current.text("cloud.error.emptySummary")
                )
            }
            return content
        } catch let error as CloudAIError {
            throw error
        } catch {
            throw CloudAIError.invalidResponse(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        let normalized = configuration.baseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty,
              let url = URL(string: "\(normalized)/\(path)") else {
            throw CloudAIError.invalidBaseURL(provider.displayName)
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAIError.invalidResponse(
                InterfaceLanguage.current.text("cloud.error.noHTTPResponse")
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
                ?? InterfaceLanguage.current.text("error.unknown")
            throw CloudAIError.http(
                provider: provider.displayName,
                statusCode: httpResponse.statusCode,
                message: Self.extractMessage(from: body)
            )
        }
    }

    private func hasTranscriptionContent(
        _ response: CloudTranscriptionResponse
    ) -> Bool {
        let text = response.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return !text.isEmpty || !(response.segments ?? []).isEmpty
    }

    private static func extractMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(body.prefix(500))
        }

        if let message = object["message"] as? String {
            return message
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return String(body.prefix(500))
    }
}

// MARK: - Response models

struct CloudTranscriptionResponse: Decodable, Sendable {
    let model: String?
    let text: String?
    let language: String?
    let duration: Double?
    let segments: [CloudTranscriptionSegment]?
}

struct CloudTranscriptionSegment: Decodable, Sendable {
    let text: String
    let start: Double?
    let end: Double?
    let speakerID: String?

    init(
        text: String,
        start: Double?,
        end: Double?,
        speakerID: String? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerID = speakerID
    }

    enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case speaker
        case speakerID = "speaker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decodeIfPresent(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end)
        speakerID = try container.decodeIfPresent(String.self, forKey: .speaker)
            ?? container.decodeIfPresent(String.self, forKey: .speakerID)
    }
}

// MARK: - SRT parsing

private enum CloudSRTParser {
    static func parse(_ raw: String) -> [CloudTranscriptionSegment] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var segments: [CloudTranscriptionSegment] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.contains("-->") else {
                index += 1
                continue
            }

            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else {
                index += 1
                continue
            }

            index += 1
            var textLines: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(
                    lines[index].trimmingCharacters(in: .whitespaces)
                )
                index += 1
            }

            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(
                    CloudTranscriptionSegment(
                        text: text,
                        start: start,
                        end: max(start + 0.2, end)
                    )
                )
            }
        }

        return segments
    }

    private static func parseTimestamp(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

// MARK: - Chat completion payloads

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

// MARK: - Errors

enum CloudAIError: LocalizedError {
    case missingAPIKey(String)
    case invalidBaseURL(String)
    case invalidResponse(String)
    case emptyTranscription(provider: String, model: String)
    case http(provider: String, statusCode: Int, message: String)

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .missingAPIKey(let provider):
            return language.format("cloud.error.missingAPIKey", provider)
        case .invalidBaseURL(let provider):
            return language.format("cloud.error.invalidBaseURL", provider)
        case .invalidResponse(let message):
            return language.format("cloud.error.invalidResponse", message)
        case .emptyTranscription(let provider, let model):
            return "\(provider) 的 \(model) 没有返回文字或时间戳。请确认音频包含语音，并检查该模型是否支持当前转写接口。"
        case .http(let provider, let statusCode, let message):
            return language.format(
                "cloud.error.http",
                provider,
                statusCode,
                message
            )
        }
    }
}
