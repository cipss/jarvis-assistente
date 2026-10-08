import SwiftUI
import AppKit
import ServiceManagement

/// §5.4 — one compact window, tabs: Generale · Agenti · Voce · Progetti · Memoria.
struct SettingsView: View {
    @Bindable var coordinator: Coordinator
    var body: some View {
        TabView {
            GeneralTab(coordinator: coordinator).tabItem { Label("Generale", systemImage: "slider.horizontal.3") }
            AgentsTab(coordinator: coordinator).tabItem { Label("Agenti", systemImage: "terminal") }
            VoiceTab(coordinator: coordinator).tabItem { Label("Voce", systemImage: "waveform") }
            ProjectsTab(registry: coordinator.registry, settings: coordinator.settings).tabItem { Label("Progetti", systemImage: "folder") }
            MemoryTab(memory: coordinator.memory).tabItem { Label("Memoria", systemImage: "brain") }
        }
        .frame(width: 580, height: 480)
    }
}

struct GeneralTab: View {
    @Bindable var coordinator: Coordinator
    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Scorciatoie") {
                LabeledContent("Tieni premuto per parlare") { ShortcutRecorder(hotkey: $s.settings.pushToTalk) }
                LabeledContent("Mostra o nascondi le sessioni") { ShortcutRecorder(hotkey: $s.settings.overlayToggle) }
                if let e = coordinator.hotkeyError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Lingua") {
                Picker("Lingua di dettatura", selection: $s.settings.speechLocale) {
                    Text("Italiano").tag("it-IT")
                    Text("English (US)").tag("en-US")
                }
                Text("Jarvis ti capisce e ti risponde in questa lingua. La ricerca delle voci Fish segue la stessa scelta.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Comportamento") {
                Toggle("Apri all'avvio del Mac", isOn: Binding(get: { s.settings.launchAtLogin }, set: { v in
                    s.settings.launchAtLogin = v
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { s.settings.launchAtLogin = false }
                }))
                Slider(value: $s.settings.overlayOpacity, in: 0.5...1) { Text("Opacità del pannello") }
                Toggle("Si attiva quando dici «Jarvis»", isOn: $s.settings.handsFree)
                    .help("Il microfono resta acceso e l'audio non esce dal Mac. Si spegne anche dal menu nella barra.")
                Toggle("Anche battendo due volte le mani", isOn: $s.settings.wakeOnClap).disabled(!s.settings.handsFree).padding(.leading, 16)
                    .help("Vale solo quando Jarvis è in attesa, mai mentre parla o lavora. Dopo il battito dici la richiesta, senza il nome.")
                Toggle("Interrompilo parlando (cancellazione dell'eco, sperimentale)", isOn: $s.settings.echoCancellation).disabled(!s.settings.handsFree).padding(.leading, 16)
                    .help("Spento: mentre parla Jarvis confronta quello che sente con quello che sta dicendo. Acceso: toglie la sua voce dal microfono, da provare con la tua voce.")
                Picker("Le richieste senza progetto partono da", selection: $s.settings.generalWorkspace) {
                    Text("Una cartella vuota").tag("")
                    ForEach(coordinator.registry.projects) { p in Text(p.name).tag(p.path) }
                }
                .help("Mail, calendario, domande: la sessione legge le istruzioni di quella cartella (per esempio il CLAUDE.md del tuo vault di note, dove c'è scritto quale posta e quale calendario usi).")
                Toggle("Apri la pagina o il sito quando una sessione li ha fatti", isOn: $s.settings.openResults)
                Toggle("Aggiornamenti a voce mentre lavora", isOn: $s.settings.speakProgress)
                Toggle("Leggi a voce il riassunto quando una sessione finisce", isOn: $s.settings.speakSummaries)
                Toggle("Silenzioso quando è attiva una Full immersion", isOn: $s.settings.muteDuringFocus)
                Toggle("Suono breve quando premi la scorciatoia", isOn: $s.settings.blipOnChordDown)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.settings.pushToTalk) { coordinator.registerHotkeys() }
        .onChange(of: s.settings.handsFree) { coordinator.refreshWake() }
        .onChange(of: s.settings.echoCancellation) { coordinator.refreshWake() }
        .onChange(of: s.settings.wakeOnClap) { coordinator.refreshWake() }
        .onChange(of: s.settings.overlayToggle) { coordinator.registerHotkeys() }
    }
}

struct AgentsTab: View {
    @Bindable var coordinator: Coordinator
    @State private var claudeVersion = "…"
    @State private var codexVersion = "…"
    @State private var geminiKeyField = ""
    @State private var hasGeminiKey = Secrets.get(Secrets.geminiKey) != nil
    @State private var geminiStatus = ""

    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Cervello di Jarvis") {
                LabeledContent("Gemini API") {
                    Text(hasGeminiKey ? "Configurata" : "Non configurata")
                        .foregroundStyle(hasGeminiKey ? .primary : .secondary)
                }
                LabeledContent("Chiave API") {
                    HStack {
                        SecureField("Incolla GEMINI_API_KEY", text: $geminiKeyField)
                            .textFieldStyle(.roundedBorder)
                        Button(hasGeminiKey ? "Sostituisci" : "Salva") { saveGeminiKey() }
                            .disabled(geminiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Text("Modello")
                    TextField("gemini-3.8-flash", text: $s.settings.geminiModel)
                        .textFieldStyle(.roundedBorder)
                    Button("Rimuovi chiave") {
                        Secrets.delete(Secrets.geminiKey)
                        hasGeminiKey = false
                        geminiStatus = "Chiave rimossa."
                    }
                    .disabled(!hasGeminiKey)
                }
                Text("Gemini è il cervello principale: decide routing, memoria, follow-up e riassunti. Claude Code e Codex restano gli esecutori.")
                    .font(.caption).foregroundStyle(.secondary)
                if !geminiStatus.isEmpty {
                    Text(geminiStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Esecutori disponibili") {
                LabeledContent("Claude Code") {
                    Text(coordinator.claudePath.map { "\($0)  ·  \(claudeVersion)" } ?? "non trovato")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Codex") {
                    Text(coordinator.codexPath.map { "\($0)  ·  \(codexVersion)" } ?? "non trovato")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Predefiniti degli esecutori") {
                Picker("Agente predefinito", selection: $s.settings.defaultAgent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Permessi di Claude", selection: $s.settings.claudePermissionMode) {
                    ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Permessi di Codex", selection: $s.settings.codexPermissionMode) {
                    ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Sessioni contemporanee al massimo: \(s.settings.maxConcurrentSessions)", value: $s.settings.maxConcurrentSessions, in: 1...6)
            }
        }
        .formStyle(.grouped)
        .task {
            if let p = coordinator.claudePath { claudeVersion = await CLILocator.version(of: p) ?? "?" }
            if let p = coordinator.codexPath { codexVersion = await CLILocator.version(of: p) ?? "?" }
        }
    }

    private func saveGeminiKey() {
        let key = geminiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if Secrets.set(key, for: Secrets.geminiKey) {
            hasGeminiKey = true
            geminiKeyField = ""
            geminiStatus = "Chiave Gemini salvata localmente."
        } else {
            geminiStatus = "Non riesco a salvare la chiave."
        }
    }
}

struct VoiceTab: View {
    @Bindable var coordinator: Coordinator
    @State private var keyField = ""
    @State private var hasKey = Secrets.get(Secrets.fishKey) != nil
    @State private var balance: String = ""
    @State private var query = ""
    @State private var voices: [FishAudio.Voice] = []
    @State private var status = ""

    var body: some View {
        @Bindable var s = coordinator.settings
        Form {
            Section("Fish Audio") {
                if hasKey {
                    LabeledContent("Chiave API") {
                        HStack { Text("Salvata su questo Mac").foregroundStyle(.secondary); Button("Rimuovi") { Secrets.delete(Secrets.fishKey); hasKey = false; balance = "" } }
                    }
                    LabeledContent("Crediti") { Text(balance.isEmpty ? "…" : balance).foregroundStyle(.secondary) }
                    Picker("Modello", selection: $s.settings.fishModel) {
                        Text("Automatico (Pro, gratuito se il credito API è finito)").tag("auto")
                        Text("S2.1 Pro, usa il credito API").tag("s2.1-pro")
                        Text("S2.1 Pro Free, gratuito").tag("s2.1-pro-free")
                    }
                    Text("I crediti del piano valgono solo sul sito di Fish. L'API scala un credito separato in dollari. Il modello Free non costa niente.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Chiave API") {
                        SecureField("Incolla la chiave di Fish Audio", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                            .onSubmit { saveKey() }
                    }
                    HStack {
                        Spacer()
                        Button("Salva") { saveKey() }.buttonStyle(.borderedProminent).disabled(keyField.isEmpty)
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Voce") {
                LabeledContent("In uso") { Text(s.settings.fishVoiceName).foregroundStyle(.secondary) }
                LabeledContent("Cerca una voce") {
                    HStack {
                        TextField("es. calma, narratore", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 160).onSubmit { Task { await search() } }
                        Button("Cerca") { Task { await search() } }.disabled(!hasKey)
                        Button("Ascolta") { coordinator.voice.speak(VoiceService.sample(coordinator.settings.settings)) }
                    }
                }
                if !voices.isEmpty {
                    List(voices) { v in
                        HStack {
                            VStack(alignment: .leading) { Text(v.title); Text(v.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if v.id == s.settings.fishVoiceID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { s.settings.fishVoiceID = v.id; s.settings.fishVoiceName = v.title }
                    }.frame(height: 120)
                }
                Slider(value: $s.settings.speakingRate, in: 0.7...1.4) { Text("Velocità") }
                Toggle("Se Fish non risponde usa la voce di sistema", isOn: $s.settings.systemVoiceFallback)
            }
        }
        .formStyle(.grouped)
        .task { await refreshBalance() }
    }

    private func saveKey() {
        let k = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if Secrets.set(k, for: Secrets.fishKey) { hasKey = true; keyField = ""; status = ""; Task { await refreshBalance() } }
        else { status = "Non riesco a salvare la chiave." }
    }

    private func refreshBalance() async {
        guard let key = Secrets.get(Secrets.fishKey) else { return }
        do { let b = try await FishAudio.balance(apiKey: key); balance = "Credito API $\(b.apiCreditUSD) · pacchetto \(b.balance.formatted()) (\(b.type))"; status = "" }
        catch { status = "Non riesco a leggere il saldo: \(error)" }
    }
    private func search() async {
        guard let key = Secrets.get(Secrets.fishKey) else { return }
        do { voices = try await FishAudio.searchVoices(apiKey: key, query: query, language: coordinator.settings.settings.voiceLanguageCode); status = "" } catch { status = "\(error)" }
    }
}

struct ProjectsTab: View {
    @Bindable var registry: ProjectRegistry
    @Bindable var settings: SettingsStore
    @State private var selection: Project.ID?
    var body: some View {
        VStack(spacing: 8) {
            Table(registry.projects, selection: $selection) {
                TableColumn("Nome") { p in EditableText(text: binding(p, \.name)) }
                TableColumn("Percorso") { p in Text(p.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                TableColumn("Soprannomi") { p in
                    EditableText(text: Binding(get: { p.aliases.joined(separator: ", ") },
                                               set: { v in var q = p; q.aliases = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; registry.update(q) }))
                }
                TableColumn("Agente") { p in
                    Picker("", selection: binding(p, \.defaultAgent)) { ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                }.width(90)
                TableColumn("Permessi") { p in
                    HStack(spacing: 4) {
                        Picker("", selection: binding(p, \.permissionMode)) { ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                        if p.permissionMode == .acceptEdits { Image(systemName: "hand.raised").foregroundStyle(.secondary).help("I comandi di shell verranno bloccati: le sessioni in background non possono approvare le richieste") }
                    }
                }.width(150)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.hasDirectoryPath else { return }
                        Task { @MainActor in registry.add(Project(name: ProjectRegistry.suggestedName(for: url), path: url.path)) }
                    }
                }
                return true
            }
            HStack {
                Button("+") { addFolder() }
                Button("−") { if let selection { registry.remove(selection) } }.disabled(selection == nil)
                Spacer()
                Text("Trascina qui una cartella per aggiungerla").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            HStack {
                Text("I progetti creati a voce vanno in").font(.caption).foregroundStyle(.secondary)
                TextField("~/Projects", text: $settings.settings.projectsRoot).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Scegli…") {
                    FolderPicker.choose(message: "Dove creo i progetti nuovi?") { settings.settings.projectsRoot = $0.path }
                }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func binding<T>(_ p: Project, _ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { registry.projects.first { $0.id == p.id }?[keyPath: kp] ?? p[keyPath: kp] },
                set: { v in var q = registry.projects.first { $0.id == p.id } ?? p; q[keyPath: kp] = v; registry.update(q) })
    }

    private func addFolder() {
        FolderPicker.choose { url in
            registry.add(Project(name: ProjectRegistry.suggestedName(for: url), path: url.path))
        }
    }
}

struct EditableText: View {
    @Binding var text: String
    var body: some View { TextField("", text: $text).textFieldStyle(.plain) }
}

/// Long-term memory: what Jarvis has been told to remember, editable by hand.
struct MemoryTab: View {
    @Bindable var memory: MemoryStore
    @State private var draft = ""
    @State private var selection: Memory.ID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Di' «ricordati che…» mentre parli oppure aggiungi una nota qui. L'orchestratore le legge a ogni turno e le passa a ogni agente che avvia.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
            List(selection: $selection) {
                ForEach(memory.memories) { m in
                    HStack(alignment: .top) {
                        Text(m.text).textSelection(.enabled)
                        Spacer()
                        Text(m.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                    }.tag(m.id)
                }
                if memory.memories.isEmpty { Text("Per ora non ricordo niente.").foregroundStyle(.tertiary) }
            }
            HStack {
                TextField("Aggiungi qualcosa da ricordare…", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Aggiungi", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("−") { if let selection { memory.remove(selection); self.selection = nil } }.disabled(selection == nil)
            }.padding(.horizontal, 12)
            HStack {
                Text("\(memory.turns.count) scambi recenti tenuti come contesto").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Azzera la conversazione") { memory.clearTurns() }.controlSize(.small).disabled(memory.turns.isEmpty)
                Button("Dimentica tutto") { memory.clearMemories() }.controlSize(.small).disabled(memory.memories.isEmpty)
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
    private func add() { memory.remember(draft); draft = "" }
}
