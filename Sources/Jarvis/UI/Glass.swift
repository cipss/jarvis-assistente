import SwiftUI

/// §5 — glass material: real Liquid Glass on macOS 26, `.ultraThinMaterial` before.
/// One shadow (hairline first), 20-pt continuous radius, no borders.
struct GlassBackground: ViewModifier {
    var radius: CGFloat = 20
    var interactive = false
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 0, y: 0.5)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 0, y: 0.5)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
    }
}

extension View {
    func glass(radius: CGFloat = 20, interactive: Bool = false) -> some View { modifier(GlassBackground(radius: radius, interactive: interactive)) }
}

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Critically damped, ~350 ms: nothing here is thrown by a gesture, so nothing overshoots.
    /// Collapses to a short cross-fade ease when Reduce Motion is on.
    static var spring: Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1.0)
    }
}

/// Press feedback on pointer-down: a small scale and dim, instantly.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduce ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension SessionStatus {
    var tint: Color {
        switch self {
        case .running: .accentColor
        case .done: .green
        case .needsInput: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8
    @State private var pulse = false
    var body: some View {
        Circle().fill(status.tint).frame(width: size, height: size)
            .background {
                // A running session breathes a soft ring; everything else sits still.
                if status == .running && !Motion.reduce {
                    Circle().stroke(status.tint.opacity(0.5), lineWidth: 1)
                        .frame(width: size, height: size)
                        .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .animation(Motion.spring, value: status)
    }
}

/// The status said in words next to its colour, so it reads without relying on hue alone.
struct StatusBadge: View {
    let status: SessionStatus
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(status: status, size: 6)
            Text(status.label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(status.tint.opacity(0.14), in: Capsule())
        .foregroundStyle(status.tint)
        .fixedSize()
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A chord drawn as physical keys: ⇧ ⌘ Spazio.
struct KeyCaps: View {
    let hotkey: Hotkey
    var size: CGFloat = 11
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(hotkey.keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: size + 10, minHeight: size + 9)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(alignment: .bottom) {
                        // Slightly heavier bottom edge, like a real keycap.
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hotkey.display)
    }
}
