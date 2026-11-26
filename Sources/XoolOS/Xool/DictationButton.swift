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
