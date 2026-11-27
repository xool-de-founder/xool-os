import SwiftUI

/// The waveform button (docs/PLAN.md 6, D): click, speak, click again; the
/// words land in the field. Esc throws the take away. The waveform moves
/// while it listens (still with Reduce Motion), and says so to VoiceOver.
struct DictationButton: View {
    /// Where the words go.
    let deliver: (String) -> Void
    var size: CGFloat = Theme.target
    @ObservedObject private var voice = VoiceBridge.shared
    @XState private var hovering = false

    var body: some View {
        let on = voice.dictating
        Button { voice.toggleDictation(deliver) } label: {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on || hovering ? Theme.text : Theme.textMuted)
                .symbolEffect(.variableColor.iterative, isActive: on && !Motion.reduced)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(on || hovering ? Theme.raised : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .xoolFocus(radius: Theme.Radius.row) { voice.toggleDictation(deliver) }
        .accessibilityLabel(on ? "Stop dictating" : "Dictate")
        .accessibilityHint("Speak, then click again. Escape cancels")
        .help(on ? "Done speaking. Esc cancels" : "Dictate")
    }
}

/// The Live button in a thread's input: on and off (the microphone stays open while it is on).
struct LiveButton: View {
    let thread: UUID
    var size: CGFloat = Theme.target
    @ObservedObject private var voice = VoiceBridge.shared
    @XState private var hovering = false

    var body: some View {
        let on = voice.isLive(thread)
        Button { voice.toggleLive(in: thread) } label: {
            Image(systemName: on ? "waveform.circle.fill" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Theme.focus : (hovering ? Theme.text : Theme.textMuted))
                .symbolEffect(.variableColor.iterative, isActive: on && voice.hearing && !Motion.reduced)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(on || hovering ? Theme.raised : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .xoolFocus(radius: Theme.Radius.row) { voice.toggleLive(in: thread) }
        .accessibilityLabel(on ? "Turn Live off" : "Turn Live on")
        .accessibilityHint("Live keeps the microphone open: you talk, the answer is spoken")
        .help(on ? "Live is on. Click to turn it off" : "Live: talk, no keys")
    }
}

/// "Live" in the thread's header: a dot and the word, on and off.
struct LiveSwitch: View {
    let thread: UUID
    @ObservedObject private var voice = VoiceBridge.shared

    var body: some View {
        let on = voice.isLive(thread)
        XoolButton(radius: Theme.Radius.chip, action: { voice.toggleLive(in: thread) }) {
            HStack(spacing: 5) {
                Circle().fill(on ? Theme.focus : Color.clear)
                    .overlay(Circle().strokeBorder(on ? Color.clear : Theme.textMuted, lineWidth: 1))
                    .frame(width: 6, height: 6)
                Text("Live").font(Theme.caption).foregroundStyle(on ? Theme.text : Theme.textMuted)
            }
            .padding(.horizontal, 8)
        }
        .accessibilityLabel(on ? "Live is on" : "Live is off")
        .accessibilityHint("Toggles the open microphone")
        .help(on ? "Live: the microphone is open" : "Turn Live on")
    }
}
