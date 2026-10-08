import Foundation

/// Direct Gemini API client used by Jarvis as the primary reasoning/orchestration brain.
struct GeminiAPI: Sendable {
    enum GeminiError: LocalizedError {
        case missingKey, invalidResponse, emptyResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Chiave Gemini API non configurata."
            case .invalidResponse: return "Risposta Gemini non valida."
            case .emptyResponse: return "Gemini non ha restituito testo."
            case .http(let code, let body): return "Gemini API HTTP \(code): \(body)"
            }
        }
    }

    let apiKey: String
    let model: String

    func generateJSON(
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]
    ) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw GeminiError.missingKey }

        let generationConfig: [String: Any] = [
            "responseFormat": [
                "text": [
                    "mimeType": "application/json",
                    "schema": schema
                ]
            ]
        ]

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "generationConfig": generationConfig
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw GeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            throw GeminiError.http(http.statusCode, "\(model): " + String((String(data: responseData, encoding: .utf8) ?? "").prefix(1200)))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw GeminiError.invalidResponse
        }

        let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeminiError.emptyResponse }

        guard let jsonData = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { throw GeminiError.invalidResponse }

        return json
    }
}
