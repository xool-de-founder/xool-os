import SwiftUI

/// The "Agents" section of the column: each agent with its face, thinking
/// agents with blinking eyes. A click opens the thread, as the pill does.
/// Under an agent, the tabs it opened, ringed in its colour; a click goes there.
struct SidebarAgents: View {
    static let maxRows = 4
    static let maxTabs = 6
    static let rowHeight: CGFloat = 28
    static let tabHeight: CGFloat = 24
    static let headerHeight: CGFloat = 22

    @ObservedObject var browser: Browser
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var runtime = ChatRuntime.shared
    @ObservedObject private var ui = XoolUI.shared

    /// The agents shown, each with the tabs it has open in this window.
    static func rows(agents: [Agent], tabs: [Tab]) -> [(agent: Agent, tabs: [Tab])] {
        var budget = maxTabs
        return agents.prefix(maxRows).map { agent in
            let mine = Array(tabs.filter { $0.ownerAgent == agent.id }.prefix(budget))
            budget -= mine.count
            return (agent, mine)
        }
    }

    static func height(agents: [Agent], tabs: [Tab]) -> CGFloat {
        let rows = rows(agents: agents, tabs: tabs)
        return headerHeight + CGFloat(rows.count) * rowHeight + CGFloat(rows.reduce(0) { $0 + $1.tabs.count }) * tabHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .font(Theme.font(Theme.Size.caption, Theme.Weight.label))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 8)
                .frame(height: Self.headerHeight, alignment: .leading)
            ForEach(Self.rows(agents: store.byActivity, tabs: browser.tabs), id: \.agent.id) { row in
                XoolButton(action: { ui.openAgent(row.agent.id) }) {
                    HStack(spacing: 8) {
                        AgentAvatar(color: row.agent.color, size: 16, thinking: runtime.state(agent: row.agent.id) == .thinking)
                        Text(row.agent.name).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .frame(height: Self.rowHeight)
                .accessibilityLabel("Agent \(row.agent.name)")
                ForEach(row.tabs, id: \.id) { tab in
                    AgentTabRow(browser: browser, tab: tab, color: row.agent.color)
                        .frame(height: Self.tabHeight)
                }
            }
        }
    }
}

/// A tab an agent works in, in the column: its ring in the agent's colour,
/// filled while it works there.
private struct AgentTabRow: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let color: AgentColor

    var body: some View {
        XoolButton(action: { browser.select(tab) }) {
            HStack(spacing: 8) {
                Circle()
                    .strokeBorder(color.solid, lineWidth: 1.6)
                    .background(Circle().fill(tab.agentWorking ? color.solid : Color.clear))
                    .frame(width: 9, height: 9)
                    .padding(.leading, 3)
                Text(tab.title.isEmpty ? (AgentDomainTrust.host(tab.address) ?? "Loading…") : tab.title)
                    .font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: SidebarAgents.tabHeight, alignment: .leading)
        }
        .frame(height: SidebarAgents.tabHeight)
        .accessibilityLabel("Tab of an agent: \(tab.title)")
    }
}
