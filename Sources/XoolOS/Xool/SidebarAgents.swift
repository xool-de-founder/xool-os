import SwiftUI

/// The "Agents" section of the column: each agent with its face, thinking
/// agents with blinking eyes. A click opens the thread, as the pill does.
struct SidebarAgents: View {
    static let maxRows = 4
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22

    static func height(count: Int) -> CGFloat { headerHeight + CGFloat(min(count, maxRows)) * rowHeight }

    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var runtime = ChatRuntime.shared
    @ObservedObject private var ui = XoolUI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .font(Theme.font(Theme.Size.caption, Theme.Weight.label))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 8)
                .frame(height: Self.headerHeight, alignment: .leading)
            ForEach(Array(store.byActivity.prefix(Self.maxRows))) { agent in
                XoolButton(action: { ui.openAgent(agent.id) }) {
                    HStack(spacing: 8) {
                        AgentAvatar(color: agent.color, size: 16, thinking: runtime.isThinking(agent: agent.id))
                        Text(agent.name).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                }
                .frame(height: Self.rowHeight)
                .accessibilityLabel("Agent \(agent.name)")
            }
        }
    }
}
