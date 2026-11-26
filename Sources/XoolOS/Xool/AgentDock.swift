import SwiftUI

/// The bar along the bottom of the window: model chip on the left, the
/// agents as coloured pills, `+`, and the Agents button at the far right.
struct AgentDock: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    @ObservedObject var runtime: ChatRuntime
    @XState private var dragging: UUID?
    private static let visibleMax = 7

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ModelChip(models: models, ui: ui)
            Divider().frame(height: 16).overlay(Theme.line)
            let pinned = store.agents.filter(\.pinned)
            let shown = Array(pinned.prefix(Self.visibleMax))
            ForEach(shown) { agent in
                AgentPill(agent: agent, ui: ui, store: store, thinking: runtime.isThinking(agent: agent.id),
                          number: (store.agents.firstIndex(of: agent) ?? 0) + 1)
                    .onDrag { dragging = agent.id; return NSItemProvider(object: agent.id.uuidString as NSString) }
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        if let dragging { store.move(dragging, before: agent.id) }
                        dragging = nil
                        return true
                    }
            }
            if pinned.count > Self.visibleMax {
                Menu {
                    ForEach(pinned.dropFirst(Self.visibleMax)) { agent in
                        Button(agent.name) { ui.openAgent(agent.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textMuted)
                        .frame(width: Theme.target, height: Theme.target)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More agents")
            }
            XoolIconButton(symbol: "plus", label: "New agent") {
                ui.editing = nil
                ui.showNewAgent = true
            }
            Spacer(minLength: Theme.Space.s)
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
            ForEach(1...9, id: \.self) { n in
                Button("") { ui.openAgent(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 40)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}

struct AgentPill: View {
    let agent: Agent
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    let thinking: Bool
    let number: Int
    @XState private var hovering = false

    private var open: Bool {
        ui.open.contains { store.thread($0)?.agentID == agent.id }
    }

    var body: some View {
        Button { ui.openAgent(agent.id) } label: {
            HStack(spacing: 6) {
                AgentAvatar(color: agent.color, size: 18, thinking: thinking)
                Text(agent.name)
                    .font(Theme.font(Theme.Size.small, Theme.Weight.label))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
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
        .accessibilityLabel("\(agent.name), agent \(number)\(thinking ? ", thinking" : "")")
        .help("\(agent.name) · ⌥\(number)")
        .contextMenu {
            Button("New thread") { ui.openAgent(agent.id, fresh: true) }
            let recent = store.threads(of: agent.id).prefix(5)
            if !recent.isEmpty {
                Menu("Recent threads") {
                    ForEach(Array(recent)) { thread in Button(thread.title) { ui.openThread(thread.id) } }
                }
            }
            Button("Edit agent…") { ui.editing = agent; ui.showNewAgent = true }
            Button("Remove from bar") { store.setPinned(agent.id, false) }
        }
    }
}
