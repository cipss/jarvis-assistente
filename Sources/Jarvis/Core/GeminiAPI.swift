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

    /// Primary model first, followed by stable fallback models.
    private var candidateModels: [String] {
        var models = [model, "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash"]
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    func generateJSON(
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw GeminiError.missingKey }

        var lastError: Error?
        for candidate in candidateModels {
            for attempt in 0..<2 {
                do {
                    return try await requestJSON(
                        model: candidate,
                        systemInstruction: systemInstruction,
                        prompt: prompt,
                        schema: schema
                    )
                } catch {
                    lastError = error
                    let retryable = (error as? GeminiError)?.statusCode.map {
                        [429, 500, 502, 503, 504].contains($0)
                    } ?? false
                    guard retryable && attempt == 0 else { break }
                    AppLog.write("gemini retry model=\(candidate) after \(error.localizedDescription)")
                    try? await Task.sleep(for: .milliseconds(900))
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
        schema: [String: Any]?
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "input": prompt,
            "system_instruction": systemInstruction,
            "store": false
        ]

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
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
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

        guard let jsonData = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        return json
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
                    return value.isEmpty ? candidate : candidate
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
        request.timeoutInterval = 30
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
