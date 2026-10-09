import Foundation

// MARK: - Agents

enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

enum PermissionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Claude: `--permission-mode acceptEdits` · Codex: `-s workspace-write`
    case acceptEdits
    /// Claude: `--permission-mode bypassPermissions` · Codex: `--dangerously-bypass-approvals-and-sandbox`
    case bypassPermissions
    var id: String { rawValue }
    var displayName: String { self == .acceptEdits ? "Solo modifiche" : "Senza permessi" }
}

// MARK: - Projects

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var aliases: [String] = []
    var defaultAgent: AgentKind = .claude
    var permissionMode: PermissionMode = .bypassPermissions

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
}

// MARK: - Sessions

enum SessionStatus: String, Codable, Sendable {
    case running, done, needsInput, failed, cancelled
    var isActive: Bool { self == .running }
    var label: String {
        switch self {
        case .running: "In corso"
        case .done: "Completata"
        case .needsInput: "Serve un input"
        case .failed: "Non riuscita"
        case .cancelled: "Annullata"
        }
    }
}

struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: String                 // short id like "s_01"
    var projectName: String
    var projectPath: String
    var agent: AgentKind
    var task: String
    var status: SessionStatus = .running
    var activity: String = ""      // e.g. "Edit src/Hero.tsx"
    var startedAt: Date = Date()
    var finishedAt: Date? = nil
    var agentSessionID: String? = nil   // claude session_id / codex thread_id, for --resume
    var resultText: String = ""         // final agent result (truncated)
    var pid: Int32? = nil
    var dismissed: Bool = false

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - Orchestrator contract (§4.2)

enum OrchestratorActionKind: String, Codable, Sendable {
    case spawn, followup, cancel, status, open, clarify, chitchat, create, sheets
}

struct OrchestratorAction: Codable, Sendable, Equatable {
    var action: OrchestratorActionKind
    var agent: AgentKind?
    var project: String?
    var sessionID: String?
    var task: String?
    var speak: String
    /// A durable fact/preference to store in long-term memory (any action may carry one). nil = nothing new.
    var remember: String? = nil
    /// A phrase identifying a memory to delete. nil = nothing to forget.
    var forget: String? = nil
    /// The task builds or changes software (sites, apps, scripts, fixes): it runs on the coding model (Opus 5.5).
    var coding: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case action, agent, project, task, speak, remember, forget, coding
        case sessionID = "session_id"
    }

    static let jsonSchema: String = """
    {"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["spawn","followup","cancel","status","open","clarify","chitchat","create"]},"agent":{"type":["string","null"],"enum":["claude","codex",null]},"project":{"type":["string","null"]},"session_id":{"type":["string","null"]},"task":{"type":["string","null"]},"speak":{"type":"string"},"remember":{"type":["string","null"]},"forget":{"type":["string","null"]},"coding":{"type":["boolean","null"]}},"required":["action","agent","project","session_id","task","speak","remember","forget","coding"]}
    """
}

// MARK: - Memory

/// One durable fact the user told Jarvis ("I prefer Tailwind", "call me Albert", "always use Codex for the API project").
struct Memory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
}

/// One exchange in the rolling conversation history (what was heard, what was said back).
struct ConversationTurn: Codable, Hashable, Sendable {
    var at: Date = Date()
    var heard: String
    var said: String
    var action: String
    var task: String? = nil
    var project: String? = nil
}

// MARK: - Settings

enum BrainMode: String, Codable, Sendable, CaseIterable, Hashable {
    case fastest
    case geminiOnly

    var displayName: String {
        switch self {
        case .fastest: "Automatico · più veloce"
        case .geminiOnly: "Solo Gemini"
        }
    }
}

struct Hotkey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey)

    static let pushToTalk = Hotkey(keyCode: 49 /* kVK_Space */, modifiers: 0x0100 | 0x0200) // cmd | shift
    static let overlay = Hotkey(keyCode: 31 /* kVK_ANSI_O */, modifiers: 0x0100 | 0x0200)
}

struct Settings: Codable, Sendable {
    var pushToTalk: Hotkey = .pushToTalk
    var overlayToggle: Hotkey = .overlay
    var launchAtLogin: Bool = false
    var overlayOpacity: Double = 1.0
    var speakSummaries: Bool = true
    /// Short spoken progress lines while a session works, not only the summary at the end.
    var speakProgress: Bool = true
    /// Hands-free: say "Jarvis". The switch is also in the menu bar.
    var handsFree: Bool = true
    /// macOS echo cancellation on the hands-free mic, needed to talk over Jarvis. Off = Jarvis only listens between replies.
    var echoCancellation: Bool = false
    /// Hands-free also starts with a double clap (only while Jarvis is idle).
    var wakeOnClap: Bool = true
    /// Folder where requests about no project start (mail, calendar, questions). Empty = `<projectsRoot>/general`.
    var generalWorkspace: String = ""
    /// Web App endpoint for direct Google Sheets edits planned by Gemini.
    var googleSheetsEndpoint: String = ""
    /// Claude model for coding tasks (building or changing software). Other tasks use the CLI default.
    var codingModel: String = "claude-opus-5-5"
    /// Primary Gemini model used as Jarvis brain/orchestrator.
    var geminiModel: String = "gemini-3.5-flash-lite"
    /// Automatico races multiple enabled providers and keeps the fastest healthy one.
    var brainMode: BrainMode = .fastest
    /// Maximum simultaneous LLM providers in the fast lane.
    var maxParallelBrains: Int = 3
    /// When a session built something to look at (an HTML page, a site on localhost), open it at the end.
    var openResults: Bool = true
    var muteDuringFocus: Bool = true
    var blipOnChordDown: Bool = true
    var defaultAgent: AgentKind = .claude
    /// Headless sessions cannot answer permission prompts, so "bypass" is the only mode where shell commands actually run.
    var claudePermissionMode: PermissionMode = .bypassPermissions
    var codexPermissionMode: PermissionMode = .bypassPermissions
    var maxConcurrentSessions: Int = 6
    /// "italiano": generic Italian male voice (not a celebrity clone), picked on 29/09/2026 from six Fish Pro samples.
    var fishVoiceID: String = "f888c2e0c08a4f16b00007c412797fbc"
    var fishVoiceName: String = "italiano (uomo)"
    /// Dictation locale for SFSpeechRecognizer; replies, summaries and voice search follow it.
    var speechLocale: String = "it-IT"
    /// "s2.1-pro" bills Fish API credit (USD); "s2.1-pro-free" is $0 and needs no API credit. "auto" tries pro, falls back to free on 402.
    var fishModel: String = "auto"
    var speakingRate: Double = 1.0
    var systemVoiceFallback: Bool = true
    var overlayOrigin: CGPoint? = nil
    var overlayVisible: Bool = true
    var onboardingComplete: Bool = false
    /// Where voice-created projects are made (§ create action).
    var projectsRoot: String = "~/Projects"
    var claudePathOverride: String? = nil
    var codexPathOverride: String? = nil

    /// Missing keys fall back to the defaults above, so a settings.json written by an older build still loads.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        pushToTalk = try c.decodeIfPresent(Hotkey.self, forKey: .pushToTalk) ?? d.pushToTalk
        overlayToggle = try c.decodeIfPresent(Hotkey.self, forKey: .overlayToggle) ?? d.overlayToggle
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        speakSummaries = try c.decodeIfPresent(Bool.self, forKey: .speakSummaries) ?? d.speakSummaries
        speakProgress = try c.decodeIfPresent(Bool.self, forKey: .speakProgress) ?? d.speakProgress
        handsFree = try c.decodeIfPresent(Bool.self, forKey: .handsFree) ?? d.handsFree
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        wakeOnClap = try c.decodeIfPresent(Bool.self, forKey: .wakeOnClap) ?? d.wakeOnClap
        generalWorkspace = try c.decodeIfPresent(String.self, forKey: .generalWorkspace) ?? d.generalWorkspace
        googleSheetsEndpoint = try c.decodeIfPresent(String.self, forKey: .googleSheetsEndpoint) ?? d.googleSheetsEndpoint
        codingModel = try c.decodeIfPresent(String.self, forKey: .codingModel) ?? d.codingModel
        let savedGeminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel)
        // Migrate the previous Jarvis default to the low-latency voice model.
        geminiModel = (savedGeminiModel == nil || savedGeminiModel == "gemini-3.8-flash" || savedGeminiModel == "gemini-3.7-flash" || savedGeminiModel == "gemini-3.6-flash")
            ? d.geminiModel
            : savedGeminiModel!
        brainMode = try c.decodeIfPresent(BrainMode.self, forKey: .brainMode) ?? d.brainMode
        maxParallelBrains = min(4, max(1, try c.decodeIfPresent(Int.self, forKey: .maxParallelBrains) ?? d.maxParallelBrains))
        openResults = try c.decodeIfPresent(Bool.self, forKey: .openResults) ?? d.openResults
        muteDuringFocus = try c.decodeIfPresent(Bool.self, forKey: .muteDuringFocus) ?? d.muteDuringFocus
        blipOnChordDown = try c.decodeIfPresent(Bool.self, forKey: .blipOnChordDown) ?? d.blipOnChordDown
        defaultAgent = try c.decodeIfPresent(AgentKind.self, forKey: .defaultAgent) ?? d.defaultAgent
        claudePermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .claudePermissionMode) ?? d.claudePermissionMode
        codexPermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .codexPermissionMode) ?? d.codexPermissionMode
        maxConcurrentSessions = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions) ?? d.maxConcurrentSessions
        fishVoiceID = try c.decodeIfPresent(String.self, forKey: .fishVoiceID) ?? d.fishVoiceID
        fishVoiceName = try c.decodeIfPresent(String.self, forKey: .fishVoiceName) ?? d.fishVoiceName
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? d.speechLocale
        fishModel = try c.decodeIfPresent(String.self, forKey: .fishModel) ?? d.fishModel
        speakingRate = try c.decodeIfPresent(Double.self, forKey: .speakingRate) ?? d.speakingRate
        systemVoiceFallback = try c.decodeIfPresent(Bool.self, forKey: .systemVoiceFallback) ?? d.systemVoiceFallback
        overlayOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .overlayOrigin)
        overlayVisible = try c.decodeIfPresent(Bool.self, forKey: .overlayVisible) ?? d.overlayVisible
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? d.onboardingComplete
        projectsRoot = try c.decodeIfPresent(String.self, forKey: .projectsRoot) ?? d.projectsRoot
        claudePathOverride = try c.decodeIfPresent(String.self, forKey: .claudePathOverride)
        codexPathOverride = try c.decodeIfPresent(String.self, forKey: .codexPathOverride)
    }

    var isItalian: Bool { speechLocale.hasPrefix("it") }
    /// Language name handed to the orchestrator for everything it says out loud.
    var replyLanguage: String { isItalian ? "Italian" : "English" }
    /// Two-letter code for Fish Audio's voice search.
    var voiceLanguageCode: String { String(speechLocale.prefix(2)) }
}
