import Foundation

/// Gemini is Jarvis's primary reasoning/orchestration brain.
/// Claude Code and Codex remain execution agents.
struct Orchestrator: Sendable {
    let gemini: GeminiAPI?
    let brain: FastBrainRouter
    var language: String = "Italian"

    static func languageRule(_ language: String) -> String {
        guard language == "Italian" else { return "" }
        return """

        Language: the user speaks Italian and the transcript is Italian dictation. Write "speak" in natural spoken Italian,
        "task" in Italian while preserving code, file names, commands and tool names. Keep Fish voice cues in English.
        Italian triggers include remember/forget/interview/status/cancel/create/open requests.
        """
    }

    static let systemPrompt = """
    You are Jarvis, a friendly voice assistant and work partner for one developer.
    Return exactly ONE JSON object and nothing else. Never run tools yourself.
    "speak" is read aloud. Emit "speak" first when possible and keep it to 18 words or fewer.
    "speak" must be safe to play immediately:
    - chitchat: the actual concise answer.
    - spawn/followup/cancel/status/open/create: a brief acknowledgement, never a claim that the action already succeeded.
    - clarify: the one short clarification question.

    The architecture is:
    - One AI brain/router coordinates Gemini, Groq, Cerebras and Claude API.
    - Gemini remains the preferred reasoning model and conversation anchor when available.
    - Groq and Cerebras provide an ultra-fast lane; Claude API is a quality lane for more complex requests.
    - Claude Code and Codex are execution agents for real work.
    All brain providers receive the same compact context. The fastest valid provider wins. Never mention the internal race to the user.

    Actions:
    - spawn: start a new execution session.
    - followup: continue an existing execution session.
    - cancel: stop one session; session_id="*" stops all.
    - status: summarize active sessions.
    - open: only open a literal project folder, terminal or editor.
    - clarify: ask one short question.
    - chitchat: greetings, thanks, memory operations and questions about Jarvis itself.
    - create: create a new project and optionally start work immediately.

    Agent choice:
    - Choose codex only when the user asks for Codex or the project default agent is Codex.
    - Otherwise choose the project's default agent.
    - If there is no project default, prefer Claude.

    "coding": true for software creation/change/fix/refactor/deploy/test work, false for non-coding work.

    Any real-world action or lookup (web, mail, calendar, files, git, Slack, ClickUp, browser, etc.) must become an execution task.
    Do not claim you performed those actions yourself.

    The task must be self-contained and imperative and preserve every concrete detail the user supplied.
    Use recent sessions, memory and history to resolve pronouns and follow-ups without asking the user to repeat themselves.
    Ask at most one clarification question.
    """

    static func jsonSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "speak": ["type": "string"],
                "action": [
                    "type": "string",
                    "enum": ["spawn","followup","cancel","status","open","clarify","chitchat","create"]
                ],
                "agent": [
                    "type": "string",
                    "enum": ["claude","codex"]
                ],
                "project": ["type": "string"],
                "session_id": ["type": "string"],
                "task": ["type": "string"],
                "remember": ["type": "string"],
                "forget": ["type": "string"],
                "coding": ["type": "boolean"]
            ],
            "required": ["speak","action"]
        ]
    }
    static func userPrompt(
        projects: String,
        sessions: String,
        maxSessions: Int,
        runningCount: Int,
        transcript: String,
        context: String?,
        memories: String,
        history: String
    ) -> String {
        let now = Date().formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "it_IT")))
        var prompt = """
        Now: \(now).

        Projects:
        \(projects)

        Active sessions (\(runningCount)/\(maxSessions)):
        \(sessions)

        Long-term memory:
        \(memories)

        Recent conversation:
        \(history)

        """
        if let context {
            prompt += "Previous turns of this same request: \(context)\n\n"
        }
        prompt += "Transcript: \"\(transcript)\""
        return prompt
    }

    struct DecisionResult: Sendable {
        let action: OrchestratorAction?
        let interactionID: String?
        let provider: FastBrainRouter.Provider?
    }

    func decide(
        transcript: String,
        projects: String,
        sessions: String,
        maxSessions: Int,
        runningCount: Int,
        context: String?,
        memories: String = "- (nothing saved yet)",
        history: String = "- (none)",
        previousInteractionID: String? = nil
    ) async -> DecisionResult {
        let prompt = Self.userPrompt(
            projects: projects,
            sessions: sessions,
            maxSessions: maxSessions,
            runningCount: runningCount,
            transcript: transcript,
            context: context,
            memories: memories,
            history: history
        )

        do {
            let result = try await brain.generateJSON(
                systemInstruction: Self.systemPrompt + Self.languageRule(language),
                prompt: prompt,
                schema: Self.jsonSchema(),
                previousGeminiInteractionID: previousInteractionID
            )
            if let action = try? JSONDecoder().decode(OrchestratorAction.self, from: result.jsonData) {
                return DecisionResult(action: action, interactionID: result.interactionID, provider: result.provider)
            }
            AppLog.write("brain router returned JSON that did not match the schema")
        } catch {
            AppLog.write("gemini orchestrator error: \(error.localizedDescription)")
            let detail: String
            if let geminiError = error as? GeminiAPI.GeminiError {
                detail = geminiError.localizedDescription
            } else {
                detail = error.localizedDescription
            }
            return DecisionResult(
                action: OrchestratorAction(
                    action: .chitchat,
                    agent: nil,
                    project: nil,
                    sessionID: nil,
                    task: nil,
                    speak: "Nessun provider AI ha risposto: \(detail)"
                ),
                interactionID: nil,
                provider: nil
            )
        }

        return DecisionResult(
            action: OrchestratorAction(
                action: .chitchat,
                agent: nil,
                project: nil,
                sessionID: nil,
                task: nil,
                speak: "Gemini ha restituito una risposta che non riesco a interpretare."
            ),
            interactionID: nil,
            provider: nil
        )
    }

    func summarize(
        task: String,
        project: String,
        result: String,
        isError: Bool,
        exitCode: Int32,
        opened: String? = nil
    ) async -> String {
        let tail = String(result.suffix(2500))
        let prompt = """
        Execution agent completed a task.
        Project: \(project)
        Task: \(task)
        Exit code: \(exitCode)
        Failed: \(isError)
        \(opened.map { "Already opened for the user: \($0)." } ?? "Nothing was opened.")
        Final output:
        \(tail.isEmpty ? "(no output)" : tail)
        """

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": ["speak": ["type": "string"]],
            "required": ["speak"]
        ]

        let system = """
        Return one concise spoken summary in \(language), about 25 words maximum.
        Sound like a warm colleague. State what changed or what failed.
        Do not invent details.
        """

        if let gemini,
           let result = try? await gemini.generateJSON(
            systemInstruction: system,
            prompt: prompt,
            schema: schema
        ),
           let speak = result.stringValue(for: "speak"),
           !speak.isEmpty {
            return speak
        }

        return isError || exitCode != 0 ? "\(project) non è andato a buon fine, guarda il log." : "\(project) è pronto."
    }
}
