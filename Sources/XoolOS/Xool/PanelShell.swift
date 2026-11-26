import SwiftUI

// The content card and the panels that grow out of it (docs/PLAN.md 8, E, F).
//
// Page and right-hand panels (the agents overview, a thread as a sidebar)
// share one rounded card: no hairline between them, only a slightly different
// ground and a gap. The card behind is the page card's own rectangle grown to
// the window's right margin; the panel's content stands still, anchored to
// that margin, and is uncovered as the page card gives way.
//
// Opening the overview, Jarvis' and the assistants' avatars fly from the row
// under the card into their places in the panel (≈ 320 ms, 30 ms apart);
// closing plays it backwards. With Reduce Motion they simply cross-fade.

/// Where things are, in the shell's own space: `dock.<id>` the avatars in the
/// row, `slot.<id>` the places they have in the panel.
struct FlightFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame under `key` (see FlightFrames).
    func reportsFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: FlightFrames.self, value: [key: proxy.frame(in: .named(PanelFlight.space))])
        })
    }
}

@MainActor
final class PanelFlight: ObservableObject {
    static let shared = PanelFlight()
    static let space = "xoolShell"
    static let duration = 0.32
    static let stagger = 0.03

    enum Phase { case closed, opening, open, closing }

    /// The avatars in the row hide while the panel has them (and while they fly).
    @Published private(set) var phase: Phase = .closed
    /// Per avatar: 0 at the row, 1 in its place in the panel.
    @Published private(set) var landed: [UUID: Bool] = [:]
    @Published private(set) var order: [UUID] = []
    var frames: [String: CGRect] = [:]
    private var ticket = 0

    var dockHidden: Bool { phase != .closed }
    var slotsHidden: Bool { phase == .opening || phase == .closing }
    var flying: Bool { phase == .opening || phase == .closing }

    /// The state at launch or when a window comes up with the panel already open.
    func sync(open: Bool) {
        guard phase == .closed || phase == .open else { return }
        phase = open ? .open : .closed
    }

    func set(open: Bool) {
        ticket += 1
        let mine = ticket
        let store = AgentStore.shared
        let ids = [store.jarvis.id] + store.assistants.map(\.id)
        if Motion.reduced {
            phase = open ? .open : .closed
            return
        }
        order = ids
        phase = open ? .opening : .closing
        var start = Transaction(); start.disablesAnimations = true
        withTransaction(start) { landed = Dictionary(uniqueKeysWithValues: ids.map { ($0, !open) }) }
        // One turn of the run loop for the panel's slots to report where they are.
        DispatchQueue.main.async { [self] in
            guard mine == ticket else { return }
            for (index, id) in ids.enumerated() {
                withAnimation(.easeOut(duration: Self.duration).delay(Double(index) * Self.stagger)) { landed[id] = open }
            }
            let total = Self.duration + Double(max(0, ids.count - 1)) * Self.stagger + 0.03
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { [self] in
                guard mine == ticket else { return }
                phase = open ? .open : .closed
            }
        }
    }
}

/// The flying avatars, over everything, while the panel opens or closes.
struct FlightLayer: View {
    @ObservedObject var flight: PanelFlight
    @ObservedObject var store: AgentStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            if flight.flying {
                ForEach(flight.order, id: \.self) { id in
                    if let agent = store.agent(id),
                       let from = flight.frames["dock.\(id)"], let to = flight.frames["slot.\(id)"] {
                        let landed = flight.landed[id] ?? false
                        let here = landed ? to : from
                        AgentAvatar(color: agent.color, size: to.width)
                            .scaleEffect(landed ? 1 : from.width / max(1, to.width))
                            .position(x: here.midX, y: here.midY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A column to the right of the page, inside the card: its content stands at
/// its full width against the card's right margin, and is uncovered as the
/// column's width grows. It stays mounted while it closes.
struct PanelColumn<Content: View>: View {
    let open: Bool
    let width: CGFloat
    /// Where the card's top is in the window.
    let top: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var keep = false

    var body: some View {
        Group {
            if open || keep {
                content().frame(width: width).padding(.trailing, Metrics.cardGap)
            }
        }
        .frame(width: open ? width + Metrics.cardGap : 0, alignment: .trailing)
        .clipped()
        .padding(.top, top)
        .padding(.bottom, AgentDock.height)
        // The window's ground under the panel, the agent row and the margins
        // (the page's own view draws it under the page).
        .background(alignment: .trailing) {
            ZStack {
                Theme.canvas
                // The card's part here: square where it continues the page's
                // strip, round at the window's side.
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: Metrics.cardRadius, topTrailingRadius: Metrics.cardRadius,
                                       style: .continuous)
                    .fill(Theme.surface)
                    .padding(.top, top).padding(.bottom, AgentDock.height).padding(.trailing, Metrics.cardGap)
            }
            .frame(width: open ? width + Metrics.cardGap : 0)
        }
        .onAppear { keep = open }
        .onChange(of: open) { _, now in
            if now { keep = true } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if !open { keep = false } }
            }
        }
    }
}

/// The card's ground where the page card gives way to a panel: the strip
/// beside the page card's right edge and the notches at its round corners, so
/// page and panel read as one card with the page set into it.
struct CardJoin: View {
    let insets: EdgeInsets

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let card = CGRect(x: insets.leading, y: insets.top,
                              width: max(0, size.width - insets.leading - insets.trailing),
                              height: max(0, size.height - insets.top - insets.bottom))
            let r = Metrics.cardRadius
            // The strip from just before the page card's right corners to this
            // view's right edge, with the page card's own outline cut out.
            let strip = CGPath(rect: CGRect(x: card.maxX - r - 2, y: card.minY,
                                            width: max(0, size.width - card.maxX + r + 2), height: card.height), transform: nil)
            let cut = RoundedRectangle(cornerRadius: r, style: .continuous).path(in: card).cgPath
            Path(strip.subtracting(cut)).fill(Theme.surface)
        }
        .allowsHitTesting(false)
    }
}
