import Foundation
import AppKit
import AVFoundation
import Observation

/// Central state machine (§2). Owns the services and drives the pill + overlay.
@MainActor @Observable
final class Coordinator {
    let settings: SettingsStore
    let registry: ProjectRegistry
    let sessions: SessionStore
    let memory: MemoryStore
    let speech: SpeechService
    let voice: VoiceService
    let pill = PillModel()

    private var runners: [String: AgentRunner] = [:]
    private var clarifyContext: String?
    private var holdStart: Date?
    private var debounceTask: Task<Void, Never>?
    private var listeningActive = false
    private var hideTask: Task<Void, Never>?
    private var blip: AVAudioPlayer?
    private var pttID: UInt32?
    private var overlayID: UInt32?
    private var escID: UInt32?
    /// Bumped by Esc so an in-flight orchestrator turn's result is dropped instead of spoken.
    private var turnGeneration = 0
    /// Per running session: the agent's latest short narration and when progress was last said out loud.
    private struct Progress { var narration = ""; var narrationAt = Date.distantPast; var spokenAt: Date?; var lastSaid = "" }
    private var progress: [String: Progress] = [:]
    private var progressLoop: Task<Void, Never>?
    let wake = WakeService()
    private var wakeConfig = ""
    private var askedWakePermissions = false

    var onPillChanged: (() -> Void)?

    private func pillDidChange() {
        onPillChanged?()
        syncEscapeHotkey()
    }

    /// Esc only exists as a hotkey while the pill is showing, so it never steals Esc from other apps.
    private func syncEscapeHotkey() {
        if pill.visible, escID == nil {
            escID = HotkeyMonitor.shared.register(Hotkey(keyCode: 53 /* kVK_Escape */, modifiers: 0), pressed: { [weak self] in self?.resetConversation() })
        } else if !pill.visible, let id = escID {
            HotkeyMonitor.shared.unregister(id); escID = nil
        }
    }

    /// Esc: abandon whatever is happening in the voice loop and start a fresh chat. Coding sessions are untouched.
    func resetConversation() {
        AppLog.write("escape: reset conversation")
        turnGeneration += 1
        voice.stop()
        if speech.isListening { Task { _ = await speech.stop() } }
        listeningActive = false; holdStart = nil
        debounceTask?.cancel(); debounceTask = nil
        hideTask?.cancel()
        clarifyContext = nil
        geminiInteractionID = nil
        memory.record(heard: "(ha premuto Esc: scambio annullato)", said: "", action: "cancelled", task: nil)
        pill.visible = false; pill.secondary = ""; pill.transcript = ""; pill.state = .listening
        pillDidChange()
    }
    /// "Pulisci" in the sessions panel: the finished sessions go and so does the conversation, so the next request
    /// starts fresh instead of leaning on mails read "un attimo fa" (29/09). Saved memories stay.
    func clearHistory() {
        sessions.clearFinished()
        memory.clearTurns()
        clarifyContext = nil
        geminiInteractionID = nil
        AppLog.write("history cleared")
    }
    var onOverlayToggle: (() -> Void)?
    var onLevelChanged: (() -> Void)?
    private(set) var hotkeyError: String?

    var claudePath: String? { CLILocator.find("claude", override: settings.settings.claudePathOverride) }
    var codexPath: String? { CLILocator.find("codex", override: settings.settings.codexPathOverride) }

    init() {
        Secrets.migrate()
        settings = SettingsStore()
        registry = ProjectRegistry()
        sessions = SessionStore()
        memory = MemoryStore()
        speech = SpeechService()
        voice = VoiceService(settings: settings)
        voice.onFinished = { [weak self] in self?.didFinishSpeaking() }
        setUpWake()
        blip = try? AVAudioPlayer(data: Self.blipWAV()); blip?.volume = 0.35; blip?.prepareToPlay()
        registerHotkeys()
        Self.rotateLogs()
        progressLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tickProgress()
                self?.refreshWake()
            }
        }
    }

    // MARK: Hands-free ("Jarvis")

    private func setUpWake() {
        wake.echoText = { [weak self] in self?.voice.echoText ?? "" }
        wake.onWake = { [weak self] trigger in
            guard let self else { return }
            AppLog.write("wake: \(trigger.rawValue)")
            // Talked over: pause, not stop, so a false alarm can resume where it was.
            if voice.isSpeaking { if trigger == .bargeIn { voice.pause(); pausedTranscript = pill.transcript } else { voice.stop() } }
            hideTask?.cancel()
            if settings.settings.blipOnChordDown { blip?.currentTime = 0; blip?.play() }
            pill.state = .listening; pill.transcript = ""; pill.secondary = ""; pill.fallbackBadge = false
            pill.visible = true; pillDidChange()
        }
        wake.onCaptureUpdate = { [weak self] text, level in
            guard let self else { return }
            pill.transcript = text; pill.level = level; onLevelChanged?(); pillDidChange()
        }
        wake.onNothingHeard = { [weak self] trigger in
            guard let self else { return }
            if trigger == .bargeIn, voice.isPaused { resumeAfterFalseAlarm(); return }
            dismissPill(after: 0.3)
        }
        wake.onCommand = { [weak self] raw, trigger in
            guard let self else { return }
            if trigger == .bargeIn, voice.isPaused {
                guard WakeService.isRealInterruption(raw) else { AppLog.write("wake: false alarm \"\(raw)\", resuming"); resumeAfterFalseAlarm(); return }
                voice.stop()
            }
            let text = Self.normalizeTranscript(raw)
            pill.state = .thinking; pill.transcript = text; pillDidChange()
            wake.setMode(.busy)
            Task { await self.handle(transcript: text); self.refreshWake() }
        }
        refreshWake()
    }

    private var pausedTranscript = ""
    private func resumeAfterFalseAlarm() {
        pill.state = .speaking; pill.transcript = pausedTranscript; pill.visible = true; pillDidChange()
        voice.resume()
        refreshWake()
    }

    /// Idempotent: runs every tick and after every state change. Off during push-to-talk (own audio engine),
    /// busy while Jarvis thinks; while it talks, the user's words over it pause it.
    func refreshWake() {
        let s = settings.settings
        let want = s.handsFree && !listeningActive
        // Hands-free needs mic + speech up front: ask at once instead of waiting for a push-to-talk press
        // (after the signing certificate changed on 29/09 macOS treated Jarvis as a new app and it just sat waiting).
        if want, !askedWakePermissions, SpeechService.micStatus == .notDetermined || SpeechService.speechStatus == .notDetermined {
            askedWakePermissions = true
            Task { let r = await SpeechService.requestPermissions(); AppLog.write("wake permissions: mic=\(r.mic) speech=\(r.speech)"); self.refreshWake() }
            return
        }
        let config = "\(s.speechLocale)|\(s.echoCancellation)"
        if wake.isRunning, (!want || config != wakeConfig) { wake.stop() }
        if want, !wake.isRunning {
            wakeConfig = config
            wake.start(locale: s.speechLocale, echoCancellation: s.echoCancellation)
        }
        wake.clapEnabled = s.wakeOnClap
        let thinking = pill.visible && pill.state == .thinking
        wake.setMode(thinking ? .busy : voice.isSpeaking ? .speaking : .idle)
    }

    // MARK: Progress updates

    /// First update after 20 s, then at most one every 45 s per session. Skips while you talk, while it is
    /// already speaking, during Focus, or with the toggle off. One session speaks per tick.
    private func tickProgress() {
        guard settings.settings.speakProgress, !listeningActive, !voice.isSpeaking,
              !(pill.visible && (pill.state == .thinking || pill.state == .clarify)),
              !(isDoNotDisturb && settings.settings.muteDuringFocus) else { return }
        let now = Date()
        let running = sessions.running.filter { $0.status == .running }
        for s in running.sorted(by: { (progress[$0.id]?.spokenAt ?? $0.startedAt) < (progress[$1.id]?.spokenAt ?? $1.startedAt) }) {
            var p = progress[s.id] ?? Progress()
            let due = p.spokenAt.map { now.timeIntervalSince($0) >= 45 } ?? (now.timeIntervalSince(s.startedAt) >= 20)
            guard due else { continue }
            var line: String?
            if !p.narration.isEmpty, p.narrationAt > (p.spokenAt ?? .distantPast) { line = p.narration }
            else if let phrase = ProgressSpeech.phrase(forActivity: s.activity) {
                line = "Sono a \(SessionStore.spoken(s.elapsed)), \(phrase)."
            }
            guard var text = line, text != p.lastSaid else { continue }
            if running.count > 1 { text = "\(s.projectName): \(text)" }
            p.spokenAt = now; p.lastSaid = line ?? text
            progress[s.id] = p
            AppLog.write("progress \(s.id): \(text)")
            pill.state = .speaking; pill.transcript = text; pill.secondary = ""; pill.visible = true; pillDidChange()
            voice.speak(text); pill.fallbackBadge = !voice.hasFishKey; pillDidChange()
            return
        }
    }

    /// Keep session logs for the sessions we still know about (≤100) and drop the rest.
    private static func rotateLogs() {
        let keep = Set((JSONStore.load([Session].self, from: AppPaths.sessions) ?? []).map { "\($0.id).ndjson" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.logs.path)) ?? []
        for f in files where f.hasSuffix(".ndjson") && !keep.contains(f) {
            try? FileManager.default.removeItem(at: AppPaths.logs.appendingPathComponent(f))
        }
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        HotkeyMonitor.shared.unregister(pttID); HotkeyMonitor.shared.unregister(overlayID)
        pttID = HotkeyMonitor.shared.register(settings.settings.pushToTalk,
                                              pressed: { [weak self] in self?.chordDown() },
                                              released: { [weak self] in self?.chordUp() })
        overlayID = HotkeyMonitor.shared.register(settings.settings.overlayToggle, pressed: { [weak self] in self?.onOverlayToggle?() })
        AppLog.write("hotkeys: ptt=\(String(describing: pttID)) overlay=\(String(describing: overlayID))")
        hotkeyError = pttID == nil ? "\(settings.settings.pushToTalk.display) è già usata da un'altra app: cambiala nelle Impostazioni." : nil
    }

    func unregisterPushToTalk() { HotkeyMonitor.shared.unregister(pttID); pttID = nil }

    // MARK: Push-to-talk (§3.6 semantics)

    private func chordDown() {
        AppLog.write("chord down")
        holdStart = Date()
        if voice.isSpeaking { voice.stop() }   // barge-in
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, holdStart != nil else { return }
            beginListening()
        }
    }

    private func chordUp() {
        AppLog.write("chord up (listening=\(listeningActive))")
        let started = holdStart; holdStart = nil
        debounceTask?.cancel(); debounceTask = nil
        guard let started, Date().timeIntervalSince(started) >= 0.15, listeningActive else { return }
        Task { await finishListening() }
    }

    private func beginListening() {
        listeningActive = true
        wake.stop()
        hideTask?.cancel()
        if settings.settings.blipOnChordDown { blip?.currentTime = 0; blip?.play() }
        pill.state = .listening; pill.transcript = ""; pill.secondary = clarifyContext ?? ""; pill.fallbackBadge = false
        pill.visible = true; pillDidChange()
        speech.start(locale: settings.settings.speechLocale)
        AppLog.write("stt start error=\(speech.error ?? "none") mic=\(SpeechService.micStatus.rawValue) speech=\(SpeechService.speechStatus.rawValue)")
        if let e = speech.error { showError(e); listeningActive = false; return }
        startLevelUpdates()
    }

    private func startLevelUpdates() {
        Task { @MainActor [weak self] in
            while let self, self.speech.isListening {
                self.pill.level = self.speech.level
                self.pill.transcript = self.speech.transcript
                self.onLevelChanged?()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Fix the mis-hearings that matter for routing before Haiku sees them.
    nonisolated static func normalizeTranscript(_ t: String) -> String {
        var s = t
        let fixes: [(String, String)] = [
            (#"\b(k|c)o[\s-]?de(x|cks|cs|ks|x's)\b"#, "Codex"), (#"\bcodecs?\b"#, "Codex"), (#"\bcode[\s-]?x\b"#, "Codex"), (#"\bcortex\b"#, "Codex"),
            (#"\bclaud\b"#, "Claude"), (#"\bclod\b"#, "Claude"), (#"\bcloud code\b"#, "Claude Code"), (#"\bcodice[\s-]?x\b"#, "Codex"), (#"\bcloud\b(?=\s+(to|and|should|can|will|code))"#, "Claude"),
        ]
        for (pat, rep) in fixes { s = s.replacingOccurrences(of: pat, with: rep, options: [.regularExpression, .caseInsensitive]) }
        return s
    }

    private func finishListening() async {
        listeningActive = false
        pill.state = .thinking; pillDidChange()
        let text = Self.normalizeTranscript(await speech.stop())
        AppLog.write("stt final: \"\(text)\"")
        pill.transcript = text; pillDidChange()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { dismissPill(after: 0.6); refreshWake(); return }
        wake.setMode(.busy)
        await handle(transcript: text)
        refreshWake()
    }

    // MARK: Orchestration (§4)

    private var orchestratorTurn: Task<Void, Never>?
    private var geminiInteractionID: String?
    private var geminiConversationModel: String?

    var geminiConfigured: Bool { Secrets.get(Secrets.geminiKey) != nil }

    func handle(transcript: String) async {
        guard geminiConfigured, let key = Secrets.get(Secrets.geminiKey) else {
            showError("Gemini API non è configurata. Inserisci la chiave nelle Impostazioni → Agenti.")
            return
        }

        // The newest utterance always wins. Do not queue a stale Gemini request behind the previous one.
        orchestratorTurn?.cancel()
        turnGeneration += 1
        let gen = turnGeneration

        let turn = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await self.handleSerialized(transcript: transcript, geminiKey: key, generation: gen)
        }
        orchestratorTurn = turn
        await turn.value
    }

    private func handleSerialized(transcript: String, geminiKey: String, generation: Int) async {
        let gen = generation
        let model = settings.settings.geminiModel

        if geminiConversationModel != model {
            geminiInteractionID = nil
            geminiConversationModel = model
        }

        let previousInteractionID = geminiInteractionID
        let conversationHistory = previousInteractionID == nil
            ? memory.turnsSummary
            : "- Conversazione precedente mantenuta da Gemini sul server."
        let gemini = GeminiAPI(apiKey: geminiKey, model: model)
        let orch = Orchestrator(gemini: gemini, language: settings.settings.replyLanguage)
        let decision = await orch.decide(
            transcript: transcript,
            projects: registry.promptSummary,
            sessions: sessions.promptSummary,
            maxSessions: settings.settings.maxConcurrentSessions,
            runningCount: sessions.running.count,
            context: clarifyContext,
            memories: memory.promptSummary,
            history: conversationHistory,
            previousInteractionID: previousInteractionID
        )

        guard !Task.isCancelled, gen == turnGeneration else {
            AppLog.write("turn dropped (escaped): \(transcript)")
            return
        }

        let action = decision.action ?? OrchestratorAction(
            action: .chitchat,
            agent: nil,
            project: nil,
            sessionID: nil,
            task: nil,
            speak: "Non ho ricevuto una decisione valida da Gemini."
        )

        if let newInteractionID = decision.interactionID {
            geminiInteractionID = newInteractionID
        }

        let priorContext = clarifyContext
        clarifyContext = nil
        AppLog.write("transcript=\"\(transcript)\" → \(action)")
        await perform(action, transcript: priorContext.map { "\($0) / \(transcript)" } ?? transcript)
    }

    /// Haiku sometimes routes "open it on localhost / in the browser" to `open`, which pops a Terminal window.
    /// Only a literal folder/terminal/editor request may reach `open`; everything else becomes agent work.
    static func sanitize(_ raw: OrchestratorAction, transcript: String) -> OrchestratorAction {
        var a = raw
        // Haiku likes to "help" by naming a mailbox the user never said (29/09: "le ultime tre email" became
        // "…su <a Gmail address>", and the session went to Gmail instead of the user's real mailbox). Drop what wasn't said.
        if let t = a.task { a.task = stripUnsaidMail(t, transcript: transcript) }
        guard a.action == .open else { return a }
        let t = transcript.lowercased()
        let wantsShell = ["terminal", "finder", "folder", "directory", "editor", "vs code", "vscode", "cursor", "xcode",
                          "terminale", "cartella"].contains { t.contains($0) }
        let wantsWork = ["localhost", "browser", "port", "http", "run ", "serve", "preview", "deploy", "test", "start", "website", "site", "app",
                         "porta", "avvia", "lancia", "fai partire", "pubblica", "anteprima", "prova", "sito"].contains { t.contains($0) }
        if wantsShell && !wantsWork { return a }
        guard a.task != nil || wantsWork else { return a }   // bare "open X" with no work verbs: honour it
        var b = a
        b.action = .followup
        b.task = a.task ?? transcript
        b.sessionID = nil
        AppLog.write("sanitize: open → followup (\"\(transcript)\")")
        return b
    }

    nonisolated static func stripUnsaidMail(_ task: String, transcript: String) -> String {
        let heard = transcript.lowercased()
        var t = task
        if let re = try? NSRegularExpression(pattern: #"\s*\b(su|da|di|in|per|on|from)?\s*[\w.+-]+@[\w-]+(\.[\w-]+)+"#, options: [.caseInsensitive]) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range, in: t) else { continue }
                let found = t[r].trimmingCharacters(in: .whitespaces).lowercased()
                if !found.split(separator: " ").contains(where: { $0.contains("@") && heard.contains($0) }) { t.removeSubrange(r) }
            }
        }
        for brand in ["gmail", "google mail", "outlook"] where !heard.contains(brand) {
            t = t.replacingOccurrences(of: #"\s*\b(su|di|in|da|on|from)?\s*"# + brand + #"\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    func perform(_ raw: OrchestratorAction, transcript: String) async {
        let a = Self.sanitize(raw, transcript: transcript)
        // Memory side-effects happen regardless of which action was chosen.
        if let f = a.forget, !f.isEmpty { let n = memory.forget(f); if n == 0 && a.action == .chitchat { say("Non avevo niente di simile in memoria."); memory.record(heard: transcript, said: "niente da dimenticare", action: "forget"); return } }
        if let r = a.remember, !r.isEmpty { memory.remember(r) }
        var speak = a.speak
        switch a.action {
        case .spawn:
            guard sessions.running.count < settings.settings.maxConcurrentSessions else { speak = "Ho già \(sessions.running.count) sessioni in corso. Aspettiamo che una finisca."; break }
            var resolved = registry.resolve(a.project) ?? (a.project == nil ? generalProject() : nil)
            // Unknown project name + a concrete task: create it on the spot rather than asking.
            if resolved == nil, let name = a.project, let task = a.task, !task.isEmpty, let made = try? createProject(named: name) {
                resolved = made
                if speak.isEmpty { speak = "Ho creato \(made.name), parto subito." }
            }
            guard let project = resolved else {
                clarifyContext = transcript
                pill.state = .clarify; pill.secondary = registry.projects.isEmpty ? "Nessun progetto: aggiungine uno nelle Impostazioni." : "Quale progetto?"
                speak = registry.projects.isEmpty ? "Non hai ancora aggiunto nessun progetto." : (a.speak.isEmpty ? "Su quale progetto?" : a.speak)
                break
            }
            guard let task = a.task, !task.isEmpty else { clarifyContext = transcript; pill.state = .clarify; speak = "Cosa deve fare?"; break }
            let agent = a.agent ?? project.defaultAgent
            if spawn(project: project, agent: agent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, agent) }
        case .followup:
            guard let task = a.task, !task.isEmpty else { speak = "Cosa deve fare?"; clarifyContext = transcript; pill.state = .clarify; break }
            if let s = resolveSession(a.sessionID, project: a.project) {
                followUp(session: s, task: task, coding: a.coding)
            } else if let project = registry.resolve(a.project) {
                // No session for that project yet — a follow-up is just a spawn.
                if spawn(project: project, agent: a.agent ?? project.defaultAgent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, project.defaultAgent) }
                else if speak.isEmpty { speak = "Parto su \(project.name)." }
            } else {
                speak = "Su quale progetto?"; clarifyContext = transcript; pill.state = .clarify
            }
        case .cancel:
            if a.sessionID == "*" { stopAll(); break }
            guard let s = resolveSession(a.sessionID, project: a.project, runningOnly: true) else { speak = sessions.running.isEmpty ? "Non c'è niente in corso." : "Quale sessione?"; break }
            stop(sessionID: s.id)
        case .status:
            if speak.isEmpty { speak = statusSentence() }
        case .open:
            if let s = resolveSession(a.sessionID, project: a.project) { open(session: s) }
            else if let p = registry.resolve(a.project) { openTerminal(at: p.url) }
            else { speak = "Quale progetto?" }
        case .clarify:
            clarifyContext = transcript
            pill.state = .clarify; pill.secondary = VoiceService.stripCues(a.speak)
        case .chitchat:
            if speak.isEmpty, a.remember != nil { speak = "Ok, me lo ricordo." }
            if speak.isEmpty, a.forget != nil { speak = "Fatto, dimenticato." }
        case .create:
            guard let name = a.project?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                clarifyContext = transcript; pill.state = .clarify; pill.secondary = "Come lo chiamo?"; speak = "Come chiamo il progetto?"; break
            }
            do {
                let project = try createProject(named: name)
                if let task = a.task, !task.isEmpty {
                    let agent = a.agent ?? settings.settings.defaultAgent
                    if spawn(project: project, agent: agent, task: task, coding: a.coding) == false { speak = spawnFailureSpeech(project, agent) }
                } else {
                    clarifyContext = transcript; pill.state = .clarify; pill.secondary = "Cosa ci costruisco?"
                    speak = "Ho creato \(project.name). Cosa ci costruisco dentro?"
                }
            } catch {
                speak = "Non sono riuscito a creare il progetto: \(error.localizedDescription)"
            }
        }
        memory.record(heard: transcript, said: speak, action: a.action.rawValue, task: a.task, project: a.project)
        say(speak)
    }

    /// Workspace for non-project requests ("riassumimi le mail", "cosa ho in calendario"). Best is a knowledge base
    /// such as a notes vault: the session reads its CLAUDE.md and memory, so it knows which mail and calendar the user
    /// has (on 29/09 a session in an empty folder went looking for Gmail). Falls back to an empty
    /// `<projectsRoot>/general` when no folder is chosen in Settings.
    func generalProject() -> Project? {
        let chosen = (settings.settings.generalWorkspace as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen, isDirectory: &isDir), isDir.boolValue {
            if let p = registry.projects.first(where: { ($0.path as NSString).expandingTildeInPath == chosen }) { return p }
            return Project(name: URL(fileURLWithPath: chosen).lastPathComponent, path: chosen, defaultAgent: .claude, permissionMode: settings.settings.claudePermissionMode)
        }
        let root = URL(fileURLWithPath: (settings.settings.projectsRoot as NSString).expandingTildeInPath, isDirectory: true)
        let dir = root.appendingPathComponent("general", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return Project(name: "Generale", path: dir.path, aliases: ["generale", "general"], defaultAgent: .claude, permissionMode: settings.settings.claudePermissionMode)
    }

    private func spawnFailureSpeech(_ p: Project, _ agent: AgentKind) -> String {
        switch lastSpawnFailure {
        case .missingCLI: "La CLI di \(agent.displayName) non è installata."
        case .missingFolder: "La cartella di \(p.name) non esiste: correggi il percorso nelle Impostazioni."
        case .launch: "Non riesco ad avviare \(agent.displayName), guarda il log."
        case nil: "Non sono riuscito a farlo partire."
        }
    }

    private func resolveSession(_ id: String?, project: String?, runningOnly: Bool = false) -> Session? {
        if let id, let s = sessions.session(id) { return s }
        let pool = runningOnly ? sessions.running : sessions.visible
        if let p = registry.resolve(project), let s = pool.first(where: { $0.projectName == p.name }) { return s }
        return pool.count == 1 ? pool.first : nil
    }

    func statusSentence() -> String {
        let r = sessions.running
        if r.isEmpty { return "Al momento non c'è niente in corso." }
        return r.map { s in
            let doing = ProgressSpeech.phrase(forActivity: s.activity).map { ", \($0)" } ?? ""
            return "\(s.projectName): sono a \(SessionStore.spoken(s.elapsed))\(doing)"
        }.joined(separator: "; ") + "."
    }

    // MARK: Sessions

    enum SpawnFailure { case missingCLI, missingFolder, launch(String) }
    private(set) var lastSpawnFailure: SpawnFailure?

    @discardableResult
    func spawn(project: Project, agent: AgentKind, task: String, resume: String? = nil, existingID: String? = nil, coding: Bool? = nil) -> Bool {
        lastSpawnFailure = nil
        guard let exe = agent == .claude ? claudePath : codexPath else { lastSpawnFailure = .missingCLI; return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.url.path, isDirectory: &isDir), isDir.boolValue else {
            lastSpawnFailure = .missingFolder
            AppLog.write("spawn refused: folder missing \(project.url.path)")
            return false
        }
        let id = existingID ?? sessions.nextID()
        if existingID == nil {
            sessions.insert(Session(id: id, projectName: project.name, projectPath: project.path, agent: agent, task: task))
        } else {
            sessions.update(id) { $0.status = .running; $0.task = task; $0.finishedAt = nil; $0.activity = ""; $0.startedAt = Date(); $0.dismissed = false }
        }
        let runner = AgentRunner(sessionID: id, agent: agent,
            onEvent: { [weak self] e in self?.handleEvent(e, for: id) },
            onExit: { [weak self] code, text in self?.handleExit(code: code, lastText: text, for: id) })
        let mode = project.permissionMode
        // Coding work on Opus 5.5 (29/09); a follow-up keeps the model its session started with.
        if let coding { codingSessions[id] = coding }
        let model = (agent == .claude && codingSessions[id] == true) ? settings.settings.codingModel : nil
        AppLog.write("spawn \(id) on \(project.name) model=\(model ?? "default")")
        do {
            try runner.start(executable: exe, task: task, cwd: project.url.path, mode: mode, resume: resume, extraGuidance: memory.agentGuidance, model: model)
            runners[id] = runner
            sessions.update(id) { $0.pid = runner.pid }
            return true
        } catch {
            lastSpawnFailure = .launch("\(error)")
            sessions.update(id) { $0.status = .failed; $0.finishedAt = Date(); $0.activity = "Avvio non riuscito: \(error)" }
            return false
        }
    }

    func followUp(session s: Session, task: String, coding: Bool? = nil) {
        if coding == true { codingSessions[s.id] = true }
        guard let project = registry.projects.first(where: { $0.name == s.projectName }) ?? registry.resolve(s.projectName) else { return }
        if s.status == .running {
            // A running headless session cannot take stdin; queue as a resume after it finishes.
            pendingFollowups[s.id, default: []].append(task)
            sessions.update(s.id) { $0.activity = "Seguito in coda" }
        } else {
            spawn(project: project, agent: s.agent, task: task, resume: s.agentSessionID, existingID: s.id)
        }
    }
    private var pendingFollowups: [String: [String]] = [:]
    private var codingSessions: [String: Bool] = [:]

    func stop(sessionID: String) {
        guard let r = runners[sessionID] else { return }
        sessions.update(sessionID) { $0.status = .cancelled; $0.activity = "Mi sto fermando…" }
        r.stop()
    }

    func stopAll() {
        for (_, r) in runners { r.kill() }
        for s in sessions.running { sessions.update(s.id) { $0.status = .cancelled; $0.finishedAt = Date() } }
    }

    private func handleEvent(_ e: AgentEvent, for id: String) {
        switch e {
        case .sessionID(let sid): sessions.update(id) { $0.agentSessionID = sid }
        case .activity(let a): sessions.update(id) { if $0.status == .running { $0.activity = a } }
        case .text(let t):
            sessions.update(id) { $0.resultText = String(t.suffix(4000)) }
            if let n = ProgressSpeech.narration(from: t) { progress[id, default: Progress()].narration = n; progress[id]?.narrationAt = Date() }
        case .needsInput: sessions.update(id) { $0.status = .needsInput }
        case .result(let t, let err):
            sessions.update(id) {
                if !t.isEmpty { $0.resultText = String(t.suffix(4000)) }
                if err && $0.status == .running { $0.status = .failed }
            }
        }
    }

    private func handleExit(code: Int32, lastText: String, for id: String) {
        AppLog.write("session \(id) exited \(code)")
        runners.removeValue(forKey: id)
        progress[id] = nil
        guard var s = sessions.session(id) else { return }
        let wasCancelled = s.status == .cancelled
        sessions.update(id) {
            $0.finishedAt = Date(); $0.pid = nil
            if $0.status == .running { $0.status = code == 0 ? .done : .failed }
            if $0.status == .cancelled { $0.activity = "" }
            if $0.status == .failed && code != 0 && $0.activity.isEmpty { $0.activity = "Uscita \(code)" }
        }
        s = sessions.session(id)!
        if let next = pendingFollowups[id]?.first {
            pendingFollowups[id]?.removeFirst()
            if pendingFollowups[id]?.isEmpty == true { pendingFollowups[id] = nil }
            followUp(session: s, task: next)
            return
        }
        var opened: String?
        if !wasCancelled, s.status == .done, settings.settings.openResults,
           let log = try? String(contentsOf: AppPaths.log(for: id), encoding: .utf8),
           let url = SessionResult.viewable(ndjson: log, resultText: s.resultText.isEmpty ? lastText : s.resultText) {
            AppLog.write("open result \(id): \(url.absoluteString)")
            NSWorkspace.shared.open(url)
            opened = url.isFileURL ? url.lastPathComponent : url.absoluteString
        }
        guard !wasCancelled, settings.settings.speakSummaries, let key = Secrets.get(Secrets.geminiKey) else { return }
        let result = s.resultText.isEmpty ? lastText : s.resultText
        let model = settings.settings.geminiModel
        Task {
            let gemini = GeminiAPI(apiKey: key, model: model)
            let summary = await Orchestrator(gemini: gemini, language: settings.settings.replyLanguage).summarize(task: s.task, project: s.projectName, result: result,
                                                                                  isError: s.status != .done, exitCode: code, opened: opened)
            announce(summary)
        }
    }

    // MARK: Create

    struct CreateError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    /// Makes `<projectsRoot>/<slug>`, `git init`s it, and registers it (reuses an existing folder or registry entry).
    @discardableResult
    func createProject(named rawName: String) throws -> Project {
        let name = rawName.replacingOccurrences(of: #"\b(project|progetto)\b"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["", "new", "a new", "another", "untitled", "site", "website", "app", "thing", "one",
                                    "nuovo", "un nuovo", "nuova", "altro", "sito", "senza titolo", "cosa"]
        if generic.contains(name.lowercased()) { throw CreateError(msg: "mi serve un nome vero, come lo chiamo?") }
        if let existing = registry.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) { return existing }
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        guard !slug.isEmpty else { throw CreateError(msg: "non ho capito il nome") }
        let root = URL(fileURLWithPath: (settings.settings.projectsRoot as NSString).expandingTildeInPath, isDirectory: true)
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path), let git = CLILocator.find("git") {
            Task.detached { _ = await CLILocator.run(git, ["init", "-q"], cwd: dir.path, timeout: 20) }
        }
        let aliases = [slug.replacingOccurrences(of: "-", with: " ")].filter { $0 != name.lowercased() }
        let agent = settings.settings.defaultAgent
        let project = Project(name: name, path: dir.path, aliases: aliases, defaultAgent: agent,
                              permissionMode: agent == .claude ? settings.settings.claudePermissionMode : settings.settings.codexPermissionMode)
        registry.add(project)
        AppLog.write("created project \(name) at \(dir.path)")
        return project
    }

    // MARK: Open

    func open(session s: Session) {
        let url = URL(fileURLWithPath: (s.projectPath as NSString).expandingTildeInPath)
        if s.agent == .claude, let sid = s.agentSessionID, s.status != .running {
            openTerminal(at: url, command: "claude --resume \(sid)")
        } else if s.agent == .codex, let sid = s.agentSessionID, s.status != .running {
            openTerminal(at: url, command: "codex resume \(sid)")
        } else {
            openTerminal(at: url)
        }
    }

    func openTerminal(at url: URL, command: String? = nil) {
        let path = url.path.replacingOccurrences(of: "'", with: "'\\''")
        var script = "tell application \"Terminal\"\nactivate\ndo script \"cd '\(path)'"
        if let command { script += "; \(command.replacingOccurrences(of: "\"", with: "\\\""))" }
        script += "\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func showLog(_ s: Session) { NSWorkspace.shared.open(AppPaths.log(for: s.id)) }

    // MARK: Voice / pill

    /// Replies are read aloud: bold markers, headings and bullets would be spoken or break the rhythm.
    nonisolated static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^\s*(#+|[-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func say(_ raw: String) {
        let text = Self.speakable(raw)
        AppLog.write("speak: \(text)")
        guard !text.isEmpty else { dismissPill(after: 0.25); return }
        if pill.state != .clarify { pill.state = .speaking }
        pill.transcript = VoiceService.stripCues(text)
        pill.visible = true; pillDidChange()
        if isDoNotDisturb && settings.settings.muteDuringFocus { dismissPill(after: 2.5); return }
        voice.speak(text)
        pill.fallbackBadge = !voice.hasFishKey
        pillDidChange()
    }

    /// Completion summaries: speak (unless DND) and flash the pill.
    func announce(_ text: String) {
        AppLog.write("announce: \(text)")
        pill.state = .speaking; pill.transcript = VoiceService.stripCues(text); pill.secondary = ""; pill.visible = true; pillDidChange()
        if isDoNotDisturb && settings.settings.muteDuringFocus { dismissPill(after: 3); return }
        voice.speak(text); pill.fallbackBadge = !voice.hasFishKey; pillDidChange()
    }

    private func didFinishSpeaking() {
        defer { refreshWake() }
        if pill.state == .clarify { dismissPill(after: 8) } else { dismissPill(after: 0.25) }
    }

    private func showError(_ msg: String) {
        pill.state = .error; pill.transcript = pill.transcript.isEmpty ? "Non ho sentito" : pill.transcript; pill.secondary = msg
        pill.visible = true; pillDidChange()
        dismissPill(after: 3)
    }

    private func dismissPill(after s: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(s))
            guard let self, !Task.isCancelled, !listeningActive, !wake.capturing else { return }
            pill.visible = false; pill.secondary = ""; pillDidChange()
        }
    }

    /// Best-effort Focus detection: macOS keeps Focus assertions in this per-user DB.
    var isDoNotDisturb: Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (o["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]] else { return false }
        return !records.isEmpty
    }

    /// 40 ms 880 Hz sine with a half-sine envelope, as 16-bit mono WAV (§5.5 — no bundled asset needed).
    nonisolated static func blipWAV() -> Data {
        let sr = 44100, n = Int(0.04 * Double(sr))
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let env = sin(Double.pi * Double(i) / Double(n))
            let v = Int16(12000 * sin(2 * Double.pi * 880 * Double(i) / Double(sr)) * env)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    // MARK: Quit

    func prepareForQuit() { wake.stop(); stopAll() }
}
