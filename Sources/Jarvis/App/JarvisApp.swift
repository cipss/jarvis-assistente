import AppKit
import SwiftUI

@main
struct JarvisMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock (§1)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: Coordinator!
    private var launched = false
    private var pendingURLs: [URL] = []
    private var statusItem: NSStatusItem!
    private var pillPanel: FloatingPanel<ListeningPillView>!
    private var overlayPanel: FloatingPanel<SessionsOverlayView>!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var observation: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Self.acquireSingleInstanceLock() else {
            // Another Jarvis is already running — bail out before touching any JSON store.
            NSApp.terminate(nil); return
        }
        coordinator = Coordinator()
    }

    nonisolated(unsafe) private static var lockFD: Int32 = -1
    /// flock on a pidfile: a second instance fails to lock and exits, so it can never overwrite the stores.
    private static func acquireSingleInstanceLock() -> Bool {
        let path = AppPaths.root.appendingPathComponent("jarvis.lock").path
        lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupTray()
        setupPanels()
        coordinator.onPillChanged = { [weak self] in self?.refreshPill() }
        coordinator.onLevelChanged = { [weak self] in self?.pillPanel.update(ListeningPillView(model: self!.coordinator.pill)) }
        coordinator.onOverlayToggle = { [weak self] in self?.toggleOverlay() }
        startObserving()
        installSignalHandlers()
        if !coordinator.settings.settings.onboardingComplete { showOnboarding() }
        if coordinator.settings.settings.overlayVisible { showOverlay() }
        launched = true
        let queued = pendingURLs; pendingURLs = []
        if !queued.isEmpty { application(NSApp, open: queued) }
    }

    private var sigSources: [DispatchSourceSignal] = []
    /// SIGTERM/SIGHUP (logout, `kill`) must still take the agent trees down — no orphans (§10.7).
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.coordinator.prepareForQuit(); exit(0) }
            src.resume()
            sigSources.append(src)
        }
    }

    /// Accessory apps get no main menu, so ⌘C/⌘V/⌘A would be dead in text fields without this.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Esci da Jarvis", action: #selector(quit), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Modifica"); editItem.submenu = edit
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // MARK: Tray (§5.3)

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateTrayIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Mostra o nascondi le sessioni", action: #selector(toggleOverlayAction), keyEquivalent: "")
        handsFreeItem = menu.addItem(withTitle: "Ascolta quando dici «Jarvis» o batti le mani", action: #selector(toggleHandsFree), keyEquivalent: "")
        handsFreeItem?.state = coordinator.settings.settings.handsFree ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Progetti…", action: #selector(showProjects), keyEquivalent: "")
        menu.addItem(withTitle: "✨ Configura Gemini…", action: #selector(showGeminiSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Impostazioni…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Rifai la configurazione iniziale", action: #selector(showOnboardingAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Informazioni su Jarvis", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Esci da Jarvis", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private var handsFreeItem: NSMenuItem?

    @objc private func toggleHandsFree() {
        coordinator.settings.settings.handsFree.toggle()
        handsFreeItem?.state = coordinator.settings.settings.handsFree ? .on : .off
        coordinator.refreshWake()
    }

    private func updateTrayIcon() {
        guard let button = statusItem.button else { return }
        let running = !coordinator.sessions.running.isEmpty
        let img = NSImage(systemSymbolName: running ? "waveform.badge.magnifyingglass" : "waveform", accessibilityDescription: "Jarvis")
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.image = img?.withSymbolConfiguration(cfg)
        button.image?.isTemplate = true
        if running {
            // Small accent badge dot drawn over the template glyph.
            let base = button.image!
            let badged = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
                return true
            }
            badged.isTemplate = false
            button.image = badged
        }
    }

    /// Event-driven UI refresh via Observation; no timers.
    private func startObserving() {
        observation = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.coordinator.sessions.sessions
                        _ = self.coordinator.settings.settings.overlayOpacity
                        _ = self.coordinator.settings.settings.pushToTalk
                        _ = self.coordinator.settings.settings.handsFree
                    } onChange: { c.resume() }
                }
                self.updateTrayIcon()
                self.handsFreeItem?.state = self.coordinator.settings.settings.handsFree ? .on : .off
                self.refreshOverlay()
                // A session Jarvis just started: show the panel top-right so it is visible without ⇧⌘O.
                let running = Set(self.coordinator.sessions.running.map(\.id))
                if !running.subtracting(self.knownRunning).isEmpty, !self.overlayPanel.isVisible { self.showOverlay() }
                self.knownRunning = running
            }
        }
    }
    private var knownRunning: Set<String> = []

    // MARK: Panels

    private func setupPanels() {
        pillPanel = FloatingPanel(content: ListeningPillView(model: coordinator.pill), draggable: false)
        pillPanel.alphaValue = 0
        overlayPanel = FloatingPanel(content: overlayView(), draggable: true)
        overlayPanel.delegate = self
        overlayPanel.alphaValue = 0
        refreshOverlay()
    }

    private func overlayView() -> SessionsOverlayView {
        SessionsOverlayView(store: coordinator.sessions, chord: coordinator.settings.settings.pushToTalk,
                            onClose: { [weak self] in self?.hideOverlay() },
                            onOpen: { [weak self] s in self?.coordinator.open(session: s) },
                            onLog: { [weak self] s in self?.coordinator.showLog(s) },
                            onReply: { [weak self] s, t in self?.coordinator.followUp(session: s, task: t) },
                            onStop: { [weak self] s in self?.coordinator.stop(sessionID: s.id) },
                            onDismiss: { [weak self] s in self?.coordinator.sessions.dismiss(s.id) },
                            onClear: { [weak self] in self?.coordinator.clearHistory() })
    }

    private func refreshOverlay() {
        overlayPanel.update(overlayView())
        overlayPanel.alphaValue = overlayPanel.isVisible ? coordinator.settings.settings.overlayOpacity : 0
        let wasOrigin = overlayPanel.frame.origin
        overlayPanel.fitToContent(anchorTopCenter: false)
        if !overlayPanel.isVisible { overlayPanel.setFrameOrigin(wasOrigin) }
    }

    private func refreshPill() {
        let model = coordinator.pill
        pillPanel.update(ListeningPillView(model: model))
        if model.visible {
            positionPillTopCenter()
            if !pillPanel.isVisible {
                pillPanel.alphaValue = 0
                pillPanel.orderFrontRegardless()
                animate(pillPanel, alpha: 1, scaleFrom: 0.96)
            }
        } else if pillPanel.isVisible {
            animate(pillPanel, alpha: 0, scaleFrom: 1) { [weak self] in Task { @MainActor in self?.pillPanel.orderOut(nil) } }
        }
    }

    private func positionPillTopCenter() {
        pillPanel.fitToContent(anchorTopCenter: true)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let size = pillPanel.frame.size
        let y = vf.maxY - 12 - size.height
        pillPanel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: y))
    }

    private func animate(_ panel: NSPanel, alpha: CGFloat, scaleFrom: CGFloat, completion: (@Sendable () -> Void)? = nil) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.1 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
        if !reduce, let layer = panel.contentView?.layer {
            let anim = CASpringAnimation(keyPath: "transform.scale")
            anim.fromValue = alpha == 1 ? scaleFrom : 1; anim.toValue = alpha == 1 ? 1 : 0.96
            anim.damping = 14; anim.stiffness = 220; anim.duration = 0.35
            layer.add(anim, forKey: "scale")
        }
    }

    private func showOverlay() {
        refreshOverlay()
        if let o = coordinator.settings.settings.overlayOrigin, NSScreen.screens.contains(where: { $0.frame.contains(o) }) {
            overlayPanel.setFrameOrigin(o)
        } else if let s = NSScreen.main {
            overlayPanel.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - 380 - 24, y: s.visibleFrame.maxY - 24 - overlayPanel.frame.height))
        }
        overlayPanel.alphaValue = 0
        overlayPanel.orderFrontRegardless()
        animate(overlayPanel, alpha: coordinator.settings.settings.overlayOpacity, scaleFrom: 0.96)
        coordinator.settings.settings.overlayVisible = true
    }

    private func hideOverlay() {
        animate(overlayPanel, alpha: 0, scaleFrom: 1) { [weak self] in Task { @MainActor in self?.overlayPanel.orderOut(nil) } }
        coordinator.settings.settings.overlayVisible = false
    }

    private func toggleOverlay() { overlayPanel.isVisible ? hideOverlay() : showOverlay() }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSPanel) === overlayPanel, overlayPanel.isVisible else { return }
        coordinator.settings.settings.overlayOrigin = overlayPanel.frame.origin
    }

    // MARK: Windows

    @objc private func toggleOverlayAction() { toggleOverlay() }

    @objc private func showSettings() { presentSettings() }
    @objc private func showGeminiSettings() { presentSettings(initialTab: .gemini) }
    @objc private func showProjects() { presentSettings() }

    private func presentSettings(initialTab: SettingsTab = .general) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Impostazioni di Jarvis"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator, initialTab: initialTab))
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showOnboardingAction() { showOnboarding() }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: OnboardingView(coordinator: coordinator) { [weak self] in self?.onboardingWindow?.close() })
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Jarvis",
                                                     .applicationVersion: "0.1",
                                                     .credits: NSAttributedString(string: "Avvia Claude Code e Codex con la voce. Tutto in locale.")])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Debug aid: write PNGs of the pill and overlay into the logs folder.
    private func snapshotPanels() {
        var targets: [(String, NSWindow)] = [("pill", pillPanel), ("overlay", overlayPanel)]
        if let w = onboardingWindow { targets.append(("onboarding", w)) }
        if let w = settingsWindow { targets.append(("settings", w)) }
        for (name, panel) in targets {
            guard let v = panel.contentView else { continue }
            AppLog.write("snapshot \(name): visible=\(panel.isVisible) frame=\(panel.frame) bounds=\(v.bounds) alpha=\(panel.alphaValue)")
            guard v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { AppLog.write("snapshot \(name): no rep"); continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
            if let tiff = img.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
                do { try png.write(to: AppPaths.logs.appendingPathComponent("\(name).png")) } catch { AppLog.write("snapshot write failed \(error)") }
            } else { AppLog.write("snapshot \(name): png failed") }
        }
    }

    /// `jarvis://say?text=...` — feed a transcript without the mic (scripting / testing hook).
    /// `jarvis://overlay` toggles the overlay.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        for url in urls {
            AppLog.write("open url: \(url)")
            switch url.host {
            case "say":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value ?? ""
                guard !text.isEmpty else { continue }
                coordinator.pill.state = .thinking; coordinator.pill.transcript = text; coordinator.pill.visible = true; refreshPill()
                Task { await coordinator.handle(transcript: text) }
            case "overlay": toggleOverlay()
            case "snapshot": snapshotPanels()
            case "settings": presentSettings()
            case "onboarding": showOnboarding()
            case "permissions":
                // Debug aid: ask for mic + speech and log what TCC answers.
                AppLog.write("permissions: mic=\(SpeechService.micStatus.rawValue) speech=\(SpeechService.speechStatus.rawValue)")
                Task { let r = await SpeechService.requestPermissions(); AppLog.write("permissions result: mic=\(r.mic) speech=\(r.speech)") }
            default: break
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = coordinator.sessions.running.count
        if running > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = running == 1 ? "Una sessione è ancora in corso" : "\(running) sessioni sono ancora in corso"
            a.informativeText = running == 1 ? "Se esci si ferma." : "Se esci si fermano."
            a.addButton(withTitle: "Esci e ferma"); a.addButton(withTitle: "Annulla")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        coordinator.prepareForQuit()
        return .terminateNow
    }
}
