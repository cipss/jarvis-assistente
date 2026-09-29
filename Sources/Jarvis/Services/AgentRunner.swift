import Foundation

/// One headless CLI subprocess per session (§3.4). Both agents share this runner;
/// only the argv and the line parser differ.
@MainActor
final class AgentRunner {
    let sessionID: String
    let agent: AgentKind
    private var process: Subprocess?
    private var logHandle: FileHandle?
    private var lastText = ""
    private var stopPresses = 0
    let onEvent: @MainActor (AgentEvent) -> Void
    let onExit: @MainActor (Int32, String) -> Void   // exit code, last text seen

    init(sessionID: String, agent: AgentKind,
         onEvent: @escaping @MainActor (AgentEvent) -> Void,
         onExit: @escaping @MainActor (Int32, String) -> Void) {
        self.sessionID = sessionID; self.agent = agent; self.onEvent = onEvent; self.onExit = onExit
    }

    var pid: Int32? { process?.pid }

    /// Sessions are headless and short-lived; anything meant to keep running must be detached.
    nonisolated static let sessionGuidance = """
    You are run headlessly by a voice assistant; nobody can answer questions, so make sensible decisions and finish the job.
    You have the user's connected tools (MCP servers: calendar, email, task managers, browsers…); use them for any
    "check / look up / find / send" request and report the answer in your final sentence(s) — that text is read aloud.
    If asked to run, serve, preview or open something: start servers DETACHED so they outlive this session
    (e.g. `nohup python3 -m http.server 6000 > /tmp/jarvis-serve.log 2>&1 &` or the project's own dev server with nohup/setsid),
    confirm the port is listening, and if asked to open it in the browser run `open http://localhost:<port>`.
    While you work, before each major step write one short sentence (max 15 words) in the same language as the task saying
    what you are about to do, the way a colleague would say it out loud ("Ora controllo i test della home"). These lines
    are read aloud as progress updates, so no code, paths longer than a file name, or markdown in them.
    When you built or changed something the user can look at (an HTML page, a site, an app, a document, an image),
    open it for them when you are done, without asking: `open <file>` for a file, or start the dev server and
    `open http://localhost:<port>` for a site. Skip it only for changes with nothing to look at, or if told not to.
    End with one short sentence stating what changed and any URL, written in the same language as the task (it is read aloud).
    """

    nonisolated static func arguments(agent: AgentKind, task: String, mode: PermissionMode, resume: String?, extraGuidance: String? = nil, model: String? = nil) -> [String] {
        let guidance = extraGuidance.map { sessionGuidance + "\n\n" + $0 } ?? sessionGuidance
        switch agent {
        case .claude:
            var a = ["-p", task, "--output-format", "stream-json", "--verbose",
                     "--append-system-prompt", guidance,
                     "--permission-mode", mode == .bypassPermissions ? "bypassPermissions" : "acceptEdits"]
            // No --strict-mcp-config here: sessions must see the user's MCP servers (calendar, mail, ClickUp…).
            if let resume { a += ["--resume", resume] }
            if let model, !model.isEmpty { a += ["--model", model] }
            return a
        case .codex:
            var a = ["exec"]
            if let resume { a += ["resume", resume] }
            a += ["--json", "--skip-git-repo-check"]
            a += mode == .bypassPermissions ? ["--dangerously-bypass-approvals-and-sandbox"] : ["-s", "workspace-write"]
            a += [task + "\n\n" + guidance]
            return a
        }
    }

    func start(executable: String, task: String, cwd: String, mode: PermissionMode, resume: String?, extraGuidance: String? = nil, model: String? = nil) throws {
        let args = Self.arguments(agent: agent, task: task, mode: mode, resume: resume, extraGuidance: extraGuidance, model: model)
        let p = try Subprocess(executable: executable, arguments: args, cwd: cwd, environment: CLILocator.childEnvironment)
        let logURL = AppPaths.log(for: sessionID)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        let agent = self.agent
        let log = logHandle
        p.onLine = { [weak self] line in
            log?.write(Data((line + "\n").utf8))
            let events = agent == .claude ? ClaudeStreamParser.parse(line: line) : CodexStreamParser.parse(line: line)
            guard !events.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for e in events {
                    if case .text(let t) = e { self.lastText = t }
                    if case .result(let t, _) = e, !t.isEmpty { self.lastText = t }
                    self.onEvent(e)
                }
            }
        }
        p.onStderr = { line in log?.write(Data(("[stderr] " + line + "\n").utf8)) }
        p.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                try? self.logHandle?.close()
                self.onExit(code, self.lastText)
            }
        }
        process = p
        p.start()
    }

    /// First press interrupts (SIGINT → SIGKILL after 3 s); second press kills immediately.
    func stop() {
        stopPresses += 1
        if stopPresses >= 2 { process?.kill() } else { process?.interrupt() }
    }

    func kill() { process?.kill() }
    var isRunning: Bool { process?.isRunning ?? false }
}
