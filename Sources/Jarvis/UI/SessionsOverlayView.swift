import SwiftUI

/// §5.2 — 380-pt glass board of session cards. Draggable via the panel's movableByWindowBackground.
struct SessionsOverlayView: View {
    let store: SessionStore
    let chord: Hotkey
    let onClose: () -> Void
    let onOpen: (Session) -> Void
    let onLog: (Session) -> Void
    let onReply: (Session, String) -> Void
    let onStop: (Session) -> Void
    let onDismiss: (Session) -> Void
    /// "Pulisci": clears the finished sessions and the conversation with them.
    let onClear: () -> Void
    @State private var now = Date()
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.visible.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(store.visible) { s in
                            SessionCard(session: s, now: now,
                                        onOpen: { onOpen(s) }, onLog: { onLog(s) }, onReply: { onReply(s, $0) },
                                        onStop: { onStop(s) }, onDismiss: { onDismiss(s) })
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.97))))
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 40), 560 - 56))
            }
        }
        .padding(12)
        .frame(width: 380)
        .frame(minHeight: 96)
        .glass(radius: 22)
        .animation(Motion.spring, value: store.visible.map(\.id))
        .task {
            // One tick per second only while something is running or recently finished — elapsed labels; otherwise idle.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !store.running.isEmpty || store.visible.contains(where: { ($0.finishedAt.map { now.timeIntervalSince($0) } ?? 0) < 660 }) { now = Date() }
            }
        }
    }

    private var finishedCount: Int { store.visible.filter { !$0.status.isActive }.count }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessioni").font(.system(size: 13, weight: .semibold))
            if !store.running.isEmpty {
                Text("\(store.running.count) in corso")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText())
            }
            Spacer()
            if finishedCount > 0 {
                Button { onClear() } label: {
                    Text("Pulisci").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
                .help("Nascondi le sessioni finite")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Chiudi il pannello")
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            HStack(spacing: 6) {
                Text("Tieni premuto").foregroundStyle(.secondary)
                KeyCaps(hotkey: chord)
                Text("e parla").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            Text("«Sul sito cambia il titolo della home e pubblica»")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

struct SessionCard: View {
    let session: Session
    let now: Date
    let onOpen: () -> Void
    let onLog: () -> Void
    let onReply: (String) -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    @State private var hover = false
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var collapsed: Bool {
        guard let f = session.finishedAt else { return false }
        return now.timeIntervalSince(f) > 600
    }

    /// Last meaningful line of what the agent said: the answer to "so what did it do?".
    private var outcome: String? {
        guard !session.status.isActive else { return nil }
        let line = session.resultText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("```") }
        return line.map { $0.replacingOccurrences(of: "**", with: "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(session.projectName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                AgentIcon(agent: session.agent, size: 12).help(session.agent.displayName)
                Spacer(minLength: 4)
                Text(timeLabel).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                StatusBadge(status: session.status)
            }
            if !collapsed {
                Text(session.task).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(1)
                if session.status == .running && !session.activity.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor)
                        Text(session.activity).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .transition(.opacity)
                }
                if let outcome, session.status != .needsInput {
                    Text(outcome)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(session.status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if session.status == .needsInput {
                    Label("Serve un tuo input: aprila e continua da lì", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
                if replying {
                    HStack(spacing: 6) {
                        TextField("Cosa deve fare adesso?", text: $reply)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .focused($replyFocused)
                            .onSubmit(sendReply)
                            .onExitCommand { replying = false }
                        Button(action: sendReply) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                                .foregroundStyle(reply.isEmpty ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(PressableStyle()).disabled(reply.isEmpty)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onAppear { replyFocused = true }
                }
            }
            if hover || replying {
                HStack(spacing: 6) {
                    action("terminal", "Apri", onOpen)
                    action("doc.text", "Log", onLog)
                    if session.status == .running || session.agentSessionID != nil {
                        action("arrowshape.turn.up.left", "Rispondi") { replying.toggle() }
                    }
                    Spacer()
                    if session.status == .running { action("stop.fill", "Ferma", onStop, tint: .red) }
                    else { action("xmark", "Chiudi", onDismiss) }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(hover ? 0.075 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) { if session.status == .running { ProgressShimmer().padding(.horizontal, 14) } }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hover = $0 }
        .animation(Motion.spring, value: hover)
        .animation(Motion.spring, value: replying)
        .animation(Motion.spring, value: session.status)
    }

    private func sendReply() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        reply = ""; replying = false
        if !t.isEmpty { onReply(t) }
    }

    private func action(_ symbol: String, _ label: String, _ act: @escaping () -> Void, tint: Color = .secondary) -> some View {
        Button(action: act) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(tint)
    }

    private var timeLabel: String {
        if session.status == .running { return SessionStore.format(now.timeIntervalSince(session.startedAt)) }
        guard let f = session.finishedAt else { return "" }
        let ago = now.timeIntervalSince(f)
        return ago < 60 ? "adesso" : "\(SessionStore.format(ago)) fa"
    }
}

/// 1-pt shimmer along the bottom edge of a running card.
struct ProgressShimmer: View {
    @State private var on = false
    var body: some View {
        GeometryReader { g in
            Capsule().fill(LinearGradient(colors: [.clear, Color.accentColor.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: g.size.width * 0.4, height: 1)
                .offset(x: (on ? 1 : -0.4) * g.size.width)
                .animation(Motion.reduce ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false), value: on)
                .onAppear { on = true }
        }
        .frame(height: 1)
    }
}
