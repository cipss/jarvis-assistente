import Foundation
import AVFoundation
import Observation

/// §3.7 — Fish Audio TTS over HTTPS (model s2.1-pro), queued playback, barge-in,
/// and AVSpeechSynthesizer fallback so the app never goes silent.
@MainActor @Observable
final class VoiceService: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Mode { case fish, system }
    private(set) var isSpeaking = false
    private(set) var lastMode: Mode = .fish
    private(set) var lastError: String?
    var onFinished: (() -> Void)?
    /// Everything said since Jarvis started talking, cues stripped: what the mic hears from the speakers,
    /// so the hands-free listener can tell Jarvis's words from the user's.
    private(set) var echoText = ""

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var settings: SettingsStore
    private var currentTask: Task<Void, Never>?
    /// Set once Fish answers 402 for the paid model; cleared on launch.
    private var proUnavailable = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        synth.delegate = self
    }

    var hasFishKey: Bool { Secrets.get(Secrets.fishKey) != nil }

    /// Line used by the "hear it" buttons, in the dictation language.
    static func sample(_ s: Settings) -> String {
        s.isItalian ? "[excited] Ciao, eccomi. Dimmi pure cosa ti serve." : "[excited] Hi, I'm ready. What do you need?"
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.append(t)
        if !isSpeaking { playNext() }
    }

    /// Talked over: hold the voice until we know it was really the user (see `WakeService.isRealInterruption`).
    private(set) var isPaused = false
    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        player?.pause()
        if synth.isSpeaking { synth.pauseSpeaking(at: .immediate) }
    }
    /// A false alarm: carry on from where it stopped.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        player?.play()
        if synth.isPaused { synth.continueSpeaking() }
    }

    /// Barge-in (§3.6): stop everything immediately.
    func stop() {
        isPaused = false
        queue.removeAll()
        currentTask?.cancel(); currentTask = nil
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if isSpeaking { isSpeaking = false; onFinished?() }
    }

    private func playNext() {
        guard !queue.isEmpty else { isSpeaking = false; onFinished?(); return }
        let text = queue.removeFirst()
        if !isSpeaking { echoText = "" }
        echoText += " " + Self.stripCues(text)
        isSpeaking = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            if let key = Secrets.get(Secrets.fishKey) {
                do {
                    let pref = settings.settings.fishModel
                    var model = pref == "auto" ? (proUnavailable ? FishAudio.freeModel : FishAudio.model) : pref
                    var data: Data
                    do {
                        data = try await FishAudio.synthesize(text: text, apiKey: key, voiceID: settings.settings.fishVoiceID, speed: settings.settings.speakingRate, model: model)
                    } catch let e as FishAudio.APIError where e.status == 402 && pref == "auto" && model != FishAudio.freeModel {
                        AppLog.write("fish: no API credit for \(model) → using \(FishAudio.freeModel)")
                        proUnavailable = true; model = FishAudio.freeModel
                        data = try await FishAudio.synthesize(text: text, apiKey: key, voiceID: settings.settings.fishVoiceID, speed: settings.settings.speakingRate, model: model)
                    }
                    guard !Task.isCancelled else { return }
                    lastMode = .fish; lastError = nil
                    play(data: data)
                    return
                } catch {
                    lastError = "\(error)"
                    AppLog.write("fish tts failed: \(error)")
                }
            }
            guard !Task.isCancelled else { return }
            if Secrets.get(Secrets.fishKey) == nil { AppLog.write("fish: no key readable → system voice") }
            if settings.settings.systemVoiceFallback { speakWithSystem(text) } else { playNext() }
        }
    }

    private func play(data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            if !isPaused { p.play() }
        } catch {
            lastError = "playback: \(error.localizedDescription)"
            speakWithSystem("")
        }
    }

    /// Fish Audio performs `[laughing]`-style cues; the system voice would read them literally, so drop them there.
    nonisolated static func stripCues(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[[^\]]{1,30}\]\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func speakWithSystem(_ rawText: String) {
        let text = Self.stripCues(rawText)
        lastMode = .system
        guard !text.isEmpty else { playNext(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: settings.settings.speechLocale)
        u.rate = Float(0.5 * settings.settings.speakingRate)
        synth.speak(u)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.playNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.isSpeaking { self.playNext() } }
    }
}

/// Fish Audio REST client. Verified against https://api.fish.audio/openapi.json at build time.
enum FishAudio {
    static let base = URL(string: "https://api.fish.audio")!
    /// Own session: short timeouts so a dead socket fails fast instead of leaving the user waiting.
    nonisolated(unsafe) static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    static let model = "s2.1-pro"       // "S2.1 Pro" — $15 / 1M chars of API credit
    static let freeModel = "s2.1-pro-free" // $0, verified working with zero API credit

    struct APIError: Error, CustomStringConvertible { let status: Int; let body: String; var description: String { "Fish \(status): \(body.prefix(120))" } }

    static func synthesize(text: String, apiKey: String, voiceID: String, speed: Double, model: String = model) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent("v1/tts"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(model, forHTTPHeaderField: "model")
        let body: [String: Any] = ["text": text, "reference_id": voiceID, "format": "mp3", "mp3_bitrate": 128,
                                   "latency": "low", "normalize": true,
                                   "prosody": ["speed": speed, "volume": 0]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Stale keep-alive sockets surface as -1005 / -1001 and succeed on retry (Fish makes the retry free).
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "") }
                return data
            } catch let e as URLError where attempt < 2 && [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(e.code) {
                lastError = e
                AppLog.write("fish tts retry \(attempt + 1) after \(e.code.rawValue)")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    struct Balance: Sendable { let balance: Int; let total: Int; let type: String; let apiCreditUSD: String }

    static func balance(apiKey: String) async throws -> Balance {
        var req = URLRequest(url: base.appendingPathComponent("wallet/self/package"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        // The HTTP API bills the separate "API credit" (USD), not the package credits — fetch both.
        var api = "?"
        var r2 = URLRequest(url: base.appendingPathComponent("wallet/self/api-credit"))
        r2.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let (d2, _) = try? await URLSession.shared.data(for: r2), let o2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] {
            api = o2["credit"] as? String ?? "?"
        }
        return Balance(balance: (o["balance"] as? Int ?? 0) + (o["extra_balance"] as? Int ?? 0), total: o["total"] as? Int ?? 0, type: o["type"] as? String ?? "", apiCreditUSD: api)
    }

    struct Voice: Identifiable, Sendable, Hashable { let id: String; let title: String; let tags: [String] }

    static func searchVoices(apiKey: String, query: String, language: String = "it") async throws -> [Voice] {
        var comps = URLComponents(url: base.appendingPathComponent("model"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "page_size", value: "20"), URLQueryItem(name: "language", value: language), URLQueryItem(name: "sort_by", value: "task_count")]
        if !query.isEmpty { items.append(URLQueryItem(name: "title", value: query)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "") }
        return items.compactMap { i in
            guard let id = i["_id"] as? String, let t = i["title"] as? String else { return nil }
            return Voice(id: id, title: t, tags: (i["tags"] as? [String] ?? []).prefix(3).map { $0 })
        }
    }
}
