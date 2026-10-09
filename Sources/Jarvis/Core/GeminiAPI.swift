import Foundation

/// Gemini API client used by Jarvis as the primary reasoning/orchestration brain.
/// Uses Google's Interactions API, the recommended API for new Gemini projects.
struct GeminiAPI: Sendable {
    enum GeminiError: LocalizedError {
        case missingKey
        case invalidResponse
        case emptyResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Chiave Gemini API non configurata."
            case .invalidResponse:
                return "Risposta Gemini non valida."
            case .emptyResponse:
                return "Gemini non ha restituito testo."
            case .http(let code, let body):
                return "Gemini API HTTP \(code): \(body)"
            }
        }

        var statusCode: Int? {
            if case .http(let code, _) = self { return code }
            return nil
        }
    }

    let apiKey: String
    let model: String

    struct InteractionResult: Sendable {
        let jsonData: Data
        let interactionID: String

        func stringValue(for key: String) -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return object[key] as? String
        }
    }

    /// One long-lived URLSession keeps the HTTPS connection warm between turns.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// Primary model first, followed by stable fallback models.
    private var candidateModels: [String] {
        let models = [model, "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    private static func thinkingLevel(for model: String) -> String {
        (model == "gemini-3.5-flash-lite" || model == "gemini-3.1-flash-lite") ? "minimal" : "low"
    }

    func generateJSON(
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]? = nil,
        previousInteractionID: String? = nil,
        onSpeakReady: (@Sendable (String) -> Void)? = nil,
        maxOutputTokens: Int = 384
    ) async throws -> InteractionResult {
        guard !apiKey.isEmpty else { throw GeminiError.missingKey }

        var lastError: Error?
        for candidate in candidateModels {
            for attempt in 0..<2 {
                do {
                    return try await requestJSON(
                        model: candidate,
                        systemInstruction: systemInstruction,
                        prompt: prompt,
                        schema: schema,
                        previousInteractionID: previousInteractionID,
                        onSpeakReady: onSpeakReady,
                        maxOutputTokens: maxOutputTokens
                    )
                } catch {
                    lastError = error
                    let retryable = (error as? GeminiError)?.statusCode.map {
                        [429, 500, 502, 503, 504].contains($0)
                    } ?? false
                    guard retryable && attempt == 0 else { break }
                    AppLog.write("gemini retry model=\(candidate) after \(error.localizedDescription)")
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }

            if let code = (lastError as? GeminiError)?.statusCode,
               ![429, 500, 502, 503, 504].contains(code) {
                throw lastError!
            }

            if candidate != candidateModels.last {
                AppLog.write("gemini fallback from \(candidate) to next model")
            }
        }

        throw lastError ?? GeminiError.invalidResponse
    }

    private func requestJSON(
        model: String,
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]?,
        previousInteractionID: String?,
        onSpeakReady: (@Sendable (String) -> Void)?,
        maxOutputTokens: Int
    ) async throws -> InteractionResult {
        if let onSpeakReady {
            return try await requestStreamingJSON(
                model: model,
                systemInstruction: systemInstruction,
                prompt: prompt,
                schema: schema,
                previousInteractionID: previousInteractionID,
                onSpeakReady: onSpeakReady,
                maxOutputTokens: maxOutputTokens
            )
        }

        var body: [String: Any] = [
            "model": model,
            "input": prompt,
            "system_instruction": systemInstruction,
            "generation_config": [
                "thinking_level": Self.thinkingLevel(for: model),
                "thinking_summaries": "none",
                "max_output_tokens": maxOutputTokens
            ]
        ]

        if let previousInteractionID {
            body["previous_interaction_id"] = previousInteractionID
        }

        if let schema {
            body["response_format"] = [
                "type": "text",
                "mime_type": "application/json",
                "schema": schema
            ]
        } else {
            body["response_format"] = [
                "type": "text",
                "mime_type": "application/json"
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw GeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data

        let (responseData, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(nessun dettaglio)"
            throw GeminiError.http(http.statusCode, "\(model): " + String(body.prefix(1800)))
        }

        guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        let outputText = root["output_text"] as? String ?? Self.extractOutputText(from: root)
        let text = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeminiError.emptyResponse }

        let cleaned: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleaned = String(text[start...end])
        } else {
            cleaned = text
        }

        guard let rawJSONData = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: rawJSONData) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        guard let interactionID = root["id"] as? String, !interactionID.isEmpty else {
            throw GeminiError.invalidResponse
        }

        let resultJSONData = try JSONSerialization.data(withJSONObject: json)
        return InteractionResult(jsonData: resultJSONData, interactionID: interactionID)
    }

    /// Stream Gemini's model output and surface the "speak" field as soon as the JSON
    /// contains both action and speak. The UI can start TTS before the complete object arrives.
    private func requestStreamingJSON(
        model: String,
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]?,
        previousInteractionID: String?,
        onSpeakReady: @Sendable (String) -> Void,
        maxOutputTokens: Int
    ) async throws -> InteractionResult {
        var body: [String: Any] = [
            "model": model,
            "input": prompt,
            "system_instruction": systemInstruction,
            "stream": true,
            "generation_config": [
                "thinking_level": Self.thinkingLevel(for: model),
                "thinking_summaries": "none",
                "max_output_tokens": maxOutputTokens
            ]
        ]

        if let previousInteractionID {
            body["previous_interaction_id"] = previousInteractionID
        }

        if let schema {
            body["response_format"] = [
                "type": "text",
                "mime_type": "application/json",
                "schema": schema
            ]
        } else {
            body["response_format"] = [
                "type": "text",
                "mime_type": "application/json"
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw GeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
                if errorBody.count > 1800 { break }
            }
            throw GeminiError.http(http.statusCode, "(model): " + String(errorBody.prefix(1800)))
        }

        var output = ""
        var interactionID: String?
        var spoke = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let eventData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else { continue }

            if let interaction = event["interaction"] as? [String: Any],
               let id = interaction["id"] as? String, !id.isEmpty {
                interactionID = id
            }
            if let id = event["id"] as? String, !id.isEmpty, interactionID == nil {
                interactionID = id
            }

            let eventType = event["event_type"] as? String ?? ""
            guard eventType == "step.delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text",
                  let chunk = delta["text"] as? String else { continue }

            output += chunk

            if !spoke,
               let action = Self.extractJSONStringValue(in: output, key: "action"),
               action != "clarify",
               let speak = Self.extractJSONStringValue(in: output, key: "speak"),
               !speak.isEmpty {
                spoke = true
                onSpeakReady(speak)
            }
        }

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let interactionID, !interactionID.isEmpty else {
            throw GeminiError.emptyResponse
        }

        let cleaned: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleaned = String(text[start...end])
        } else {
            cleaned = text
        }

        guard let rawJSONData = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: rawJSONData) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        let resultJSONData = try JSONSerialization.data(withJSONObject: json)
        return InteractionResult(jsonData: resultJSONData, interactionID: interactionID)
    }

    private static func extractJSONStringValue(in text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let colon = text[keyRange.upperBound...].firstIndex(of: ":") else { return nil }

        var i = text.index(after: colon)
        while i < text.endIndex, text[i].isWhitespace {
            i = text.index(after: i)
        }
        guard i < text.endIndex, text[i] == "\"" else { return nil }

        i = text.index(after: i)
        var escaped = false
        var encoded = "\""
        while i < text.endIndex {
            let ch = text[i]
            encoded.append(ch)
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                guard let data = encoded.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data) as? String else { return nil }
                return value
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func extractOutputText(from root: [String: Any]) -> String {
        // REST Interactions responses expose model output in:
        // steps[] -> { type: "model_output", content: [{ type: "text", text: "..." }] }
        if let steps = root["steps"] as? [[String: Any]] {
            return steps.compactMap { step in
                guard let content = step["content"] as? [[String: Any]] else { return nil }
                return content.compactMap { item -> String? in
                    guard item["type"] as? String == "text" else { return nil }
                    return item["text"] as? String
                }.joined()
            }.joined()
        }

        // Keep compatibility with SDK-like responses that may expose output directly.
        if let output = root["output"] as? [[String: Any]] {
            return output.compactMap { item in
                if let text = item["text"] as? String { return text }
                if let content = item["content"] as? [[String: Any]] {
                    return content.compactMap { $0["text"] as? String }.joined()
                }
                return nil
            }.joined()
        }

        return ""
    }

    /// Performs a real inference call, not just a model metadata lookup.
    func testConnection() async throws -> String {
        var lastError: Error?
        for candidate in candidateModels {
            for attempt in 0..<2 {
                do {
                    let value = try await requestText(
                        model: candidate,
                        systemInstruction: "Respond with exactly: OK",
                        prompt: "Connection test."
                    )
                    return value.isEmpty ? candidate : value
                } catch {
                    lastError = error
                    let retryable = (error as? GeminiError)?.statusCode.map {
                        [429, 500, 502, 503, 504].contains($0)
                    } ?? false
                    guard retryable && attempt == 0 else { break }
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            if let code = (lastError as? GeminiError)?.statusCode,
               ![429, 500, 502, 503, 504].contains(code) {
                throw lastError!
            }
        }
        throw lastError ?? GeminiError.invalidResponse
    }

    private func requestText(
        model: String,
        systemInstruction: String,
        prompt: String
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "input": prompt,
            "system_instruction": systemInstruction,
            "generation_config": ["thinking_level": "low", "thinking_summaries": "none"],
            "response_format": [
                "type": "text",
                "mime_type": "text/plain"
            ],
            "store": false
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw GeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "(nessun dettaglio)"
            throw GeminiError.http(http.statusCode, "\(model): " + String(body.prefix(1500)))
        }

        guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }
        return (root["output_text"] as? String ?? Self.extractOutputText(from: root))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
