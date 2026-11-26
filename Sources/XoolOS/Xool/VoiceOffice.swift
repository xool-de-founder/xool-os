import SwiftUI

/// What the voice is doing, for the office and the menu bar (docs/PLAN.md 9, A).
enum VoiceStatus: Equatable {
    case missing, installing, starting, ready, listening, thinking, speaking

    var title: String {
        switch self {
        case .missing: return "Voice not set up"
        case .installing: return "Installing"
        case .starting: return "Waking up"
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Whether something is going on (the dot moves).
    var active: Bool { self == .listening || self == .thinking || self == .speaking || self == .installing || self == .starting }
}

/// A small dot and the word: ready, listening, thinking, speaking, or what is missing.
struct VoiceStatusLine: View {
    @ObservedObject private var voice = VoiceBridge.shared
    @ObservedObject private var setup = LocalSetup.shared
    @XState private var pulse = false

    var body: some View {
        let status = voice.status
        HStack(spacing: 5) {
            Circle()
                .fill(status == .missing ? Color.clear : (status == .ready ? Theme.textMuted : Theme.focus))
                .overlay(Circle().strokeBorder(status == .missing ? Theme.textMuted : Color.clear, lineWidth: 1))
                .frame(width: 6, height: 6)
                .opacity(status.active && pulse && !Motion.reduced ? 0.35 : 1)
                .animation(status.active && !Motion.reduced ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(status.title).font(Theme.small).foregroundStyle(Theme.textMuted)
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice: \(status.title)")
    }
}

/// The waveform button in Jarvis' office: opens the conversation (the microphone stays open, a pause
/// ends your sentence, you can talk over him) and ends it.
struct ConversationButton: View {
    var size: CGFloat = Theme.target
    @ObservedObject private var voice = VoiceBridge.shared
    @XState private var hovering = false

    var body: some View {
        let on = voice.conversing || voice.handsFree || voice.listeningNow
        Button { VoiceBridge.shared.toggleConversation() } label: {
            Image(systemName: on ? "waveform.circle.fill" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Theme.focus : (hovering ? Theme.text : Theme.textMuted))
                .symbolEffect(.variableColor.iterative, isActive: on && !Motion.reduced)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(on || hovering ? Theme.raised : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .xoolFocus(radius: Theme.Radius.row) { VoiceBridge.shared.toggleConversation() }
        .accessibilityLabel(on ? "End the conversation with Jarvis" : "Talk to Jarvis")
        .accessibilityHint("Starts a conversation: the microphone stays open")
        .help(on ? "End the conversation" : "Talk to Jarvis. ⌥⌘J")
    }
}

/// "Set up the voice": one click installs the ears, the mouth and the phrases, with progress.
/// Shown in the office while the better voice is missing; gone when it is there.
struct VoiceSetupCard: View {
    @ObservedObject private var voice = VoiceBridge.shared
    @ObservedObject private var setup = LocalSetup.shared

    var body: some View {
        if setup.running {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Setting up the voice")
                        .font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Pill("Stop") { setup.cancel() }
                }
                ProgressView(value: setup.download ?? (Double(max(setup.step - 1, 0)) / Double(max(setup.steps, 1))))
                    .progressViewStyle(.linear).tint(Theme.focus)
                // The newest readable line (not a raw download bar of some library).
                if let last = setup.lines.last(where: { !$0.contains("|") || $0.contains("▕") }) {
                    Text(last).font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Setting up the voice. \(setup.title)")
        } else if case .failed(let what, let next) = setup.phase, !SidecarEngine.installed {
            VStack(alignment: .leading, spacing: 6) {
                Label(what, systemImage: "exclamationmark.triangle").font(Theme.small).foregroundStyle(Theme.text)
                Text("Next: \(next)").font(Theme.small).foregroundStyle(Theme.textMuted)
                HStack { Spacer(); Pill("Try again", filled: true) { setup.start(onlyVoice: true) } }
            }
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
        } else if !SidecarEngine.installed {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up the voice (about 2.5 GB)").font(Theme.body).foregroundStyle(Theme.text)
                    Text("Jarvis then hears and speaks on this Mac, no cloud. Until then he speaks with the Mac's own voice.")
                        .font(Theme.small).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Pill("Set up", filled: true) { setup.start(onlyVoice: true) }
            }
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
        }
    }
}
