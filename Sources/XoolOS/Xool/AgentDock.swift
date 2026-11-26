import SwiftUI

/// The row under the card, bottom right and nothing else (docs/PLAN.md 8.1):
/// `+ · More · Assistant 3 · 2 · 1 · Jarvis · Agents`, flush right: the Agents
/// button on the card's right edge, Jarvis next to it, his assistants to its
/// left, the chip with the other agents, `+` at the far left. While the
/// overview is open, Jarvis and the assistants are in the panel, not here.
struct AgentDock: View {
    /// The row's height; the page leaves this much under it.
    static let height: CGFloat = 40
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var flight: PanelFlight
    @XState private var moreOpen = false

    var body: some View {
        let jarvis = store.jarvis
        let assistants = store.assistants
        let order = [jarvis] + assistants
        HStack(spacing: Theme.Space.xs) {
            XoolIconButton(symbol: "plus", label: "New agent") {
                ui.editing = nil
                ui.showNewAgent = true
            }
            if !store.further.isEmpty { moreChip(store.further) }
            // Jarvis sits next to the button; his assistants to his left.
            ForEach(Array(assistants.reversed())) { agent in
                pill(agent, number: (order.firstIndex(of: agent) ?? 0) + 1)
            }
            pill(jarvis, number: 1)
            XoolButton(action: { ui.toggleAgents() }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .medium))
                    Text("Agents").font(Theme.small)
                }
                .foregroundStyle(ui.showAgents ? Theme.text : Theme.textMuted)
                .padding(.horizontal, Theme.Space.s)
            }
            .accessibilityLabel("Agents overview")
            .keyboardShortcut("a", modifiers: [.command, .shift])
            // ⌥1–⌥9 call agent 1–9; no visible trace.
            .background {
                ForEach(1...9, id: \.self) { n in
                    Button("") { ui.openAgent(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
            }
        }
        // Flush right, as far from the edge as the card is.
        .padding(.trailing, Metrics.cardGap)
        .frame(height: Self.height)
    }

    private func pill(_ agent: Agent, number: Int) -> some View {
        AgentPill(agent: agent, ui: ui, store: store, state: runtime.state(agent: agent.id), number: number)
            // In the panel while it is open, and while the avatars fly.
            .opacity(flight.dockHidden ? 0 : 1)
            .allowsHitTesting(!flight.dockHidden)
            .animation(flight.dockHidden ? nil : Theme.motion(Theme.hoverTime), value: flight.dockHidden)
    }

    /// "+4": the agents that are neither Jarvis nor his assistants.
    private func moreChip(_ agents: [Agent]) -> some View {
        XoolButton(action: { moreOpen.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                Text("\(agents.count)").font(Theme.font(Theme.Size.caption, Theme.Weight.label)).monospacedDigit()
            }
            .foregroundStyle(moreOpen ? Theme.text : Theme.textMuted)
            .padding(.horizontal, 8)
            .frame(height: Theme.target)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.raised))
        }
        .accessibilityLabel("More agents, \(agents.count)")
        .help("More agents")
        .popover(isPresented: $moreOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(agents) { agent in
                    XoolButton(action: { moreOpen = false; ui.openAgent(agent.id) }) {
                        HStack(spacing: Theme.Space.s) {
                            AgentAvatar(color: agent.color, size: 20, thinking: runtime.isThinking(agent: agent.id))
                            Text(agent.name).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.s).frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel(agent.name)
                }
            }
            .padding(6).frame(width: 220)
        }
    }
}

struct AgentPill: View {
    let agent: Agent
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    let state: AgentActivity
    let number: Int
    private var thinking: Bool { state == .thinking }

    /// What the pill says besides the face: how many tabs it works in, or
    /// that it waits for you.
    private var stateText: String {
        switch state {
        case .idle: return ""
        case .thinking: return ", thinking"
        case .browsing(let n): return ", working in the browser, \(n) tab\(n == 1 ? "" : "s")"
        case .waiting: return ", waiting for you"
        case .listening: return ", listening to you"
        }
    }
    @XState private var hovering = false

    private var open: Bool {
        ui.open.contains { store.thread($0)?.agentID == agent.id }
    }

    var body: some View {
        Button {
            // ⌥-click on Jarvis: straight to listening (docs/PLAN.md 8, G).
            if agent.isMain, NSEvent.modifierFlags.contains(.option) { VoiceBridge.shared.listenToJarvis() }
            else { ui.openAgent(agent.id) }
        } label: {
            HStack(spacing: 6) {
                AgentAvatar(color: agent.color, size: 18, thinking: thinking)
                    .reportsFrame("dock.\(agent.id)")
                Text(agent.name)
                    .font(Theme.font(Theme.Size.small, Theme.Weight.label))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                switch state {
                case .browsing(let n):
                    HStack(spacing: 2) {
                        Image(systemName: "square.on.square").font(.system(size: 9, weight: .medium))
                        Text("\(n)").font(Theme.font(Theme.Size.caption, Theme.Weight.label)).monospacedDigit()
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(agent.color.solid.opacity(0.25)))
                case .waiting:
                    Circle().fill(agent.color.solid).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 1.5).padding(-1.5))
                case .listening:
                    Image(systemName: "waveform").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .symbolEffect(.variableColor.iterative, isActive: !Motion.reduced)
                        .padding(.horizontal, 4).frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(agent.color.solid.opacity(0.25)))
                    Text("listening").font(Theme.caption).foregroundStyle(Theme.textMuted)
                default: EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.target)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(hovering ? agent.color.solid.opacity(0.2) : agent.color.bg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(agent.color.solid.opacity(open ? 0.9 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .xoolFocus(radius: Theme.Radius.chip) { ui.openAgent(agent.id) }
        .accessibilityLabel("\(agent.name), agent \(number)\(stateText)")
        .help(agent.isMain ? "\(agent.name) · ⌥\(number) · ⌥-click to talk" : "\(agent.name) · ⌥\(number)")
        .contextMenu {
            Button("New thread") { ui.openAgent(agent.id, fresh: true) }
            let recent = store.threads(of: agent.id).prefix(5)
            if !recent.isEmpty {
                Menu("Recent threads") {
                    ForEach(Array(recent)) { thread in Button(thread.title) { ui.openThread(thread.id) } }
                }
            }
            Button("Edit agent…") { ui.editing = agent; ui.showNewAgent = true }
            if agent.isMain {
                Button("Talk to Jarvis") { VoiceBridge.shared.listenToJarvis() }
            } else {
                Button("Remove from assistants") { store.setAssistant(agent.id, false) }
            }
        }
    }
}
