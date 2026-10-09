import Foundation

/// Multi-provider reasoning router for low-latency voice turns.
/// Enabled providers run concurrently; the first valid structured response wins.
/// This keeps Gemini as the primary brain while allowing faster infrastructure to answer.
struct FastBrainRouter: Sendable {
    enum Provider: String, Sendable, Hashable {
        case gemini
        case groq
        case cerebras
        case anthropic

        var displayName: String {
            switch self {
            case .gemini: "Gemini"
            case .groq: "Groq"
            case .cerebras: "Cerebras"
            case .anthropic: "Claude"
            }
        }
    }

    enum RouterError: LocalizedError {
        case noProvider
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "Nessun provider AI configurato."
            case .invalidResponse(let provider):
                return "\(provider) non ha restituito una risposta valida."
            }
        }
    }

    struct Result: Sendable {
        let jsonData: Data
        let provider: Provider
        let interactionID: String?
    }

    private struct CandidateResult: Sendable {
        let result: Result
        let latency: TimeInterval
    }

    private struct ProviderSpec: Sendable {
        let provider: Provider
        let key: String
        let model: String?
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    let mode: BrainMode
    let maxParallel: Int
    let gemini: GeminiAPI?
    let groqKey: String?
    let cerebrasKey: String?
    let anthropicKey: String?

    init(
        mode: BrainMode,
        maxParallel: Int,
        gemini: GeminiAPI?,
        groqKey: String?,
        cerebrasKey: String?,
        anthropicKey: String?
    ) {
        self.mode = mode
        self.maxParallel = min(4, max(1, maxParallel))
        self.gemini = gemini
        self.groqKey = groqKey
        self.cerebrasKey = cerebrasKey
        self.anthropicKey = anthropicKey
    }

    func generateJSON(
        systemInstruction: String,
        prompt: String,
        schema: [String: Any]?,
        previousGeminiInteractionID: String? = nil
    ) async throws -> Result {
        // [String: Any] is not Sendable under Swift 6 strict concurrency; freeze it before spawning provider tasks.
        let schemaData = schema.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let specs = candidateSpecs(prompt: prompt)
        guard !specs.isEmpty else { throw RouterError.noProvider }

        let selected = Array(specs.prefix(maxParallel))

        let winner: CandidateResult? = await withTaskGroup(of: CandidateResult?.self) { group -> CandidateResult? in
            for spec in selected {
                group.addTask {
                    let t = Date()
                    do {
                        let result = try await self.request(
                            spec: spec,
                            systemInstruction: systemInstruction,
                            prompt: prompt,
                            schemaData: schemaData,
                            previousGeminiInteractionID: previousGeminiInteractionID
                        )
                        return CandidateResult(result: result, latency: Date().timeIntervalSince(t))
                    } catch {
                        AppLog.write("brain provider=\(spec.provider.rawValue) failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            while let item = await group.next() {
                guard let item else { continue }
                await BrainLatencyBook.shared.record(provider: item.result.provider, seconds: item.latency)
                AppLog.write("brain winner=\(item.result.provider.rawValue) latency=\(Int(item.latency * 1000))ms")
                group.cancelAll()
                return item
            }
            return nil
        }

        guard let winner else { throw RouterError.noProvider }
        return winner.result
    }

    private func candidateSpecs(prompt: String) -> [ProviderSpec] {
        switch mode {
        case .geminiOnly:
            guard let gemini else { return [] }
            return [ProviderSpec(provider: .gemini, key: gemini.apiKey, model: gemini.model)]
        case .fastest:
            break
        }

        let simple = prompt.count < 700 &&
            !prompt.localizedCaseInsensitiveContains("analizza") &&
            !prompt.localizedCaseInsensitiveContains("confronta") &&
            !prompt.localizedCaseInsensitiveContains("spiegazione") &&
            !prompt.localizedCaseInsensitiveContains("architettura")

        let order: [Provider] = simple
            ? [.cerebras, .groq, .gemini, .anthropic]
            : [.cerebras, .gemini, .anthropic, .groq]

        var specs: [ProviderSpec] = []
        for provider in order {
            switch provider {
            case .gemini:
                if let gemini {
                    specs.append(.init(provider: .gemini, key: gemini.apiKey, model: gemini.model))
                }
            case .groq:
                if let groqKey, !groqKey.isEmpty {
                    specs.append(.init(provider: .groq, key: groqKey, model: "openai/gpt-oss-20b"))
                }
            case .cerebras:
                if let cerebrasKey, !cerebrasKey.isEmpty {
                    specs.append(.init(provider: .cerebras, key: cerebrasKey, model: "gpt-oss-120b"))
                }
            case .anthropic:
                if let anthropicKey, !anthropicKey.isEmpty {
                    specs.append(.init(provider: .anthropic, key: anthropicKey, model: "claude-haiku-5-5"))
                }
            }
        }
        return specs
    }

    private func request(
        spec: ProviderSpec,
        systemInstruction: String,
        prompt: String,
        schemaData: Data?,
        previousGeminiInteractionID: String?
    ) async throws -> Result {
        switch spec.provider {
        case .gemini:
            guard let gemini else { throw RouterError.invalidResponse("Gemini") }
            let schema = schemaData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let result = try await gemini.generateJSON(
                systemInstruction: systemInstruction,
                prompt: prompt,
                schema: schema,
                previousInteractionID: previousGeminiInteractionID
            )
            return Result(jsonData: result.jsonData, provider: .gemini, interactionID: result.interactionID)

        case .groq:
            return try await requestOpenAICompatible(
                provider: .groq,
                baseURL: "https://api.groq.com/openai/v1/chat/completions",
                model: spec.model ?? "openai/gpt-oss-20b",
                key: spec.key,
                systemInstruction: systemInstruction,
                prompt: prompt
            )

        case .cerebras:
            return try await requestOpenAICompatible(
                provider: .cerebras,
                baseURL: "https://api.cerebras.ai/v1/chat/completions",
                model: spec.model ?? "gpt-oss-120b",
                key: spec.key,
                systemInstruction: systemInstruction,
                prompt: prompt
            )

        case .anthropic:
            return try await requestAnthropic(
                model: spec.model ?? "claude-haiku-5-5",
                key: spec.key,
                systemInstruction: systemInstruction,
                prompt: prompt
            )
        }
    }

    private func requestOpenAICompatible(
        provider: Provider,
        baseURL: String,
        model: String,
        key: String,
        systemInstruction: String,
        prompt: String
    ) async throws -> Result {
        guard let url = URL(string: baseURL) else { throw RouterError.invalidResponse(provider.displayName) }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 384,
            "response_format": ["type": "json_object"],
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RouterError.invalidResponse(provider.displayName)
        }
        guard (200..<300).contains(http.statusCode) else {
            var error = ""
            for try await line in bytes.lines {
                error += line + "\n"
                if error.count > 1200 { break }
            }
            throw GeminiAPI.GeminiError.http(http.statusCode, "\(provider.displayName): \(error.prefix(1200))")
        }

        var output = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String else { continue }
            output += piece
            if let json = Self.extractJSONObject(from: output) {
                return Result(jsonData: json, provider: provider, interactionID: nil)
            }
        }

        guard let json = Self.extractJSONObject(from: output) else {
            throw RouterError.invalidResponse(provider.displayName)
        }
        return Result(jsonData: json, provider: provider, interactionID: nil)
    }

    private func requestAnthropic(
        model: String,
        key: String,
        systemInstruction: String,
        prompt: String
    ) async throws -> Result {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw RouterError.invalidResponse("Claude")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 384,
            "system": systemInstruction,
            "messages": [["role": "user", "content": prompt]],
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RouterError.invalidResponse("Claude")
        }
        guard (200..<300).contains(http.statusCode) else {
            var error = ""
            for try await line in bytes.lines {
                error += line + "\n"
                if error.count > 1200 { break }
            }
            throw GeminiAPI.GeminiError.http(http.statusCode, "Claude: \(error.prefix(1200))")
        }

        var output = ""
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let piece = delta["text"] as? String else { continue }
            output += piece
            if let json = Self.extractJSONObject(from: output) {
                return Result(jsonData: json, provider: .anthropic, interactionID: nil)
            }
        }

        guard let json = Self.extractJSONObject(from: output) else {
            throw RouterError.invalidResponse("Claude")
        }
        return Result(jsonData: json, provider: .anthropic, interactionID: nil)
    }

    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start

        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let objectText = String(text[start...i])
                        return objectText.data(using: .utf8)
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

/// Rolling latency telemetry used to see which provider is winning in real usage.
/// The race itself is deliberately parallel: latency is observed without ever serialising the fast lane.
actor BrainLatencyBook {
    static let shared = BrainLatencyBook()
    private var ema: [FastBrainRouter.Provider: Double] = [:]

    func record(provider: FastBrainRouter.Provider, seconds: TimeInterval) {
        let previous = ema[provider] ?? seconds
        ema[provider] = previous * 0.8 + seconds * 0.2
    }

    func snapshot() -> [FastBrainRouter.Provider: Double] { ema }
}
