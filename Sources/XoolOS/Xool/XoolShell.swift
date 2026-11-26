import SwiftUI

/// Xool's layer around the browser window: the agent bar along the bottom,
/// the thread (floating or as a column), and the overviews.
struct XoolShell<Content: View>: View {
    let browser: Browser
    let content: Content
    @ObservedObject private var ui = XoolUI.shared
    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var runtime = ChatRuntime.shared

    init(browser: Browser, @ViewBuilder content: () -> Content) {
        self.browser = browser
        self.content = content()
    }

    var body: some View {
        // The window runs to the bottom (the column too); the agent row
        // sits under the page only, bottom right (docs/PLAN.md 6.1). The
        // page leaves it its room (ContentView: AgentDock.height).
        HStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                content
                if ui.mode == .floating, ui.hasThreads, !ui.minimized {
                    FloatingThread(ui: ui, store: store, runtime: runtime, models: models)
                        .padding(.bottom, AgentDock.height)
                }
                if ui.showTabs {
                    TabsOverview(browser: browser, ui: ui)
                        .padding(.bottom, AgentDock.height)
                }
                if ui.showBrain {
                    BrainView(ui: ui, browser: browser)
                        .padding(.bottom, AgentDock.height)
                        .transition(.opacity)
                }
                if ui.showMedia {
                    MediaView(ui: ui, browser: browser)
                        .padding(.bottom, AgentDock.height)
                        .transition(.opacity)
                }
                AgentDock(ui: ui, store: store, models: models, runtime: runtime)
            }
            if ui.showAgents {
                AgentsOverview(ui: ui, store: store, models: models, runtime: runtime)
            }
            if ui.sidebarOpen {
                ThreadSidebar(ui: ui, store: store, runtime: runtime, models: models)
            }
        }
        .animation(Theme.motion(Theme.grow), value: ui.hasThreads)
        .animation(Theme.motion(Theme.grow), value: ui.minimized)
        .animation(Theme.motion(Theme.morph), value: ui.mode)
        .animation(Theme.motion(Theme.grow), value: ui.showAgents)
        .animation(Theme.motion(Theme.grow), value: ui.showTabs)
        .animation(Theme.motion(Theme.grow), value: ui.showBrain)
        .animation(Theme.motion(Theme.grow), value: ui.showMedia)
        .sheet(isPresented: $ui.showNewAgent) {
            AgentEditor(ui: ui, store: store, models: models, editing: ui.editing)
        }
        .task {
            await models.refresh()
            VoiceBridge.shared.install()
            XoolUI.shared.applyLaunchRequest()
        }
    }
}
