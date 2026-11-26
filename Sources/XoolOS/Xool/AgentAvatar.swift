import SwiftUI

/// The agent's face: a squircle blob in its colour with two eyes. While it
/// thinks, the eyes blink; with Reduce Motion they stay open.
struct AgentAvatar: View {
    let color: AgentColor
    var size: CGFloat = 20
    var thinking = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                .fill(color.solid)
            if thinking && !Motion.reduced {
                TimelineView(.animation(minimumInterval: 0.08)) { context in
                    eyes(open: Self.open(at: context.date))
                }
            } else {
                eyes(open: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Closed for 140 ms out of every 1.3 s.
    static func open(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3)
        return t < 0.14 ? 0.12 : 1
    }

    private func eyes(open: CGFloat) -> some View {
        HStack(spacing: size * 0.2) {
            Capsule().frame(width: size * 0.14, height: size * 0.26 * open)
            Capsule().frame(width: size * 0.14, height: size * 0.26 * open)
        }
        .foregroundStyle(Color(nsColor: Theme.NS.color(0x0E0F11)).opacity(0.85))
        .offset(y: -size * 0.02)
    }
}
