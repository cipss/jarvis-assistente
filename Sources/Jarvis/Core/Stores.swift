import Foundation
import Observation

@MainActor @Observable
final class SettingsStore {
    var settings: Settings { didSet { JSONStore.save(settings, to: AppPaths.settings) } }
    init() { settings = JSONStore.load(Settings.self, from: AppPaths.settings) ?? Settings() }
}

@MainActor @Observable
final class ProjectRegistry {
    var projects: [Project] { didSet { JSONStore.save(projects, to: AppPaths.projects) } }
    init() { projects = JSONStore.load([Project].self, from: AppPaths.projects) ?? [] }

    func add(_ p: Project) { projects.append(p) }
    func remove(_ id: Project.ID) { projects.removeAll { $0.id == id } }
    func update(_ p: Project) { if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } }

    /// Exact name, then alias, then case-insensitive substring.
    func resolve(_ name: String?) -> Project? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        if let p = projects.first(where: { $0.name.lowercased() == name }) { return p }
        if let p = projects.first(where: { $0.aliases.contains { $0.lowercased() == name } }) { return p }
        // Fuzzy: whole-word containment either way, preferring the longest (most specific) project name.
        func words(_ x: String) -> Set<String> { Set(x.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }) }
        let q = words(name)
        let candidates = projects.filter { p in
            let pw = words(p.name.lowercased()) ; guard !pw.isEmpty else { return false }
            return pw.isSubset(of: q) || q.isSubset(of: pw) || p.aliases.contains { words($0.lowercased()).isSubset(of: q) }
        }
        return candidates.max { words($0.name).count < words($1.name).count }
    }

    /// Summary block for the orchestrator prompt (§4.1).
    var promptSummary: String {
        projects.isEmpty ? "- (none registered yet)" :
        projects.map { "- \($0.name) · \($0.path) · [\($0.aliases.joined(separator: ", "))] · \($0.defaultAgent.rawValue)" }.joined(separator: "\n")
    }

    static func suggestedName(for url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}

@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private var counter: Int

    init() {
        let loaded = JSONStore.load([Session].self, from: AppPaths.sessions) ?? []
        // Anything marked running at launch was orphaned by a previous crash — kill + mark failed (§10.7).
        sessions = loaded.map { s in
            var s = s
            if s.status == .running {
                if let pid = s.pid, Subprocess.isAlive(pid) { Subprocess.killGroup(pid) }
                s.status = .failed; s.finishedAt = s.finishedAt ?? Date(); s.activity = "Interrotta dal riavvio dell'app"
            }
            return s
        }
        counter = loaded.compactMap { Int($0.id.dropFirst(2)) }.max() ?? 0
        if loaded.contains(where: { $0.status == .running }) { JSONStore.save(sessions, to: AppPaths.sessions) }
    }

    var running: [Session] { sessions.filter { $0.status == .running } }
    var visible: [Session] {
        sessions.filter { !$0.dismissed }.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            return $0.startedAt > $1.startedAt
        }
    }

    func nextID() -> String { counter += 1; return String(format: "s_%02d", counter) }

    func insert(_ s: Session) { sessions.insert(s, at: 0); trimAndSave() }
    func update(_ id: String, _ mutate: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i]); trimAndSave()
    }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
    func dismiss(_ id: String) { update(id) { $0.dismissed = true } }
    func clearFinished() { for s in sessions where !s.status.isActive { dismiss(s.id) } }

    private func trimAndSave() {
        if sessions.count > 100 { sessions = Array(sessions.prefix(100)) }
        JSONStore.save(sessions, to: AppPaths.sessions)
    }

    /// Compact summary for the orchestrator prompt: keep voice turns small and fast.
    var promptSummary: String {
        let recent = sessions.filter { !$0.dismissed }.prefix(4)
        guard !recent.isEmpty else { return "- (none)" }
        return recent.map { s in
            var line = "- \(s.id) · \(s.projectName) · \(s.agent.rawValue) · \(s.status.rawValue) · \"\(s.task.prefix(60))\""
            if s.status == .running, !s.activity.isEmpty {
                line += " · now: \(s.activity.prefix(60))"
            }
            if let end = s.finishedAt {
                line += " · finished \(Int(Date().timeIntervalSince(end) / 60))m ago"
                let r = s.resultText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if !r.isEmpty { line += " · result: \"\(r.prefix(800))\"" }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Elapsed time the way it is said out loud: "40 secondi", "3 minuti", "un'ora e 5 minuti".
    static func spoken(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) secondi" }
        let m = s / 60
        if s < 3600 { return m == 1 ? "un minuto" : "\(m) minuti" }
        let h = s / 3600, rm = (s % 3600) / 60
        let hs = h == 1 ? "un'ora" : "\(h) ore"
        return rm == 0 ? hs : "\(hs) e \(rm) minuti"
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
    }
}

/// Long-term memory (§ memory): facts the user asked Jarvis to keep, plus a short rolling conversation history.
/// Facts are injected into every orchestrator turn and into every coding-agent session; turns only into the orchestrator.
@MainActor @Observable
final class MemoryStore {
    private(set) var memories: [Memory] { didSet { JSONStore.save(memories, to: AppPaths.memory) } }
    private(set) var turns: [ConversationTurn] { didSet { JSONStore.save(turns, to: AppPaths.conversation) } }
    static let maxMemories = 200
    static let maxTurns = 12

    init() {
        memories = JSONStore.load([Memory].self, from: AppPaths.memory) ?? []
        turns = JSONStore.load([ConversationTurn].self, from: AppPaths.conversation) ?? []
    }

    /// Adds a fact; near-duplicates (case-insensitive) are replaced so the list never accumulates repeats.
    func remember(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        memories.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        memories.append(Memory(text: text))
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        AppLog.write("memory +: \(text)")
    }

    /// Removes memories matching the phrase (case-insensitive substring, either direction). Returns how many were dropped.
    @discardableResult
    func forget(_ phrase: String) -> Int {
        let q = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let before = memories.count
        memories.removeAll { let m = $0.text.lowercased(); return m.contains(q) || q.contains(m) }
        AppLog.write("memory -: \(phrase) (\(before - memories.count) removed)")
        return before - memories.count
    }

    func remove(_ id: Memory.ID) { memories.removeAll { $0.id == id } }
    func clearMemories() { memories = [] }
    func clearTurns() { turns = [] }

    func record(heard: String, said: String, action: String, task: String? = nil, project: String? = nil) {
        turns.append(ConversationTurn(heard: heard, said: said, action: action, task: task, project: project))
        if turns.count > Self.maxTurns { turns.removeFirst(turns.count - Self.maxTurns) }
    }

    /// Block for the orchestrator prompt.
    var promptSummary: String {
        guard !memories.isEmpty else { return "- (nothing saved yet)" }
        let lines = memories.suffix(24).map { "- \($0.text)" }.joined(separator: "\n")
        return String(lines.prefix(5000))
    }

    /// Recent exchanges, oldest first, for the orchestrator prompt.
    /// Recent exchanges, oldest first, for the orchestrator prompt.
    var turnsSummary: String {
        guard !turns.isEmpty else { return "- (none)" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return turns.suffix(6).map { t in
            var line = "- [\(f.localizedString(for: t.at, relativeTo: Date()))] heard: \"\(t.heard.prefix(180))\" → \(t.action)"
            if let p = t.project, !p.isEmpty { line += " project=\"\(p)\"" }
            if !t.said.isEmpty { line += " · said: \"\(t.said.prefix(180))\"" }
            return line
        }.joined(separator: "\n")
    }

    /// Text appended to coding-agent sessions so they honour the user's standing preferences.
    var agentGuidance: String? {
        memories.isEmpty ? nil :
        "Standing preferences the developer has told the assistant to remember (honour any that apply; ignore the rest):\n" + memories.map { "- \($0.text)" }.joined(separator: "\n")
    }
}
