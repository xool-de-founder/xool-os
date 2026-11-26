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
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    content
                    if ui.sidebarOpen {
                        ThreadSidebar(ui: ui, store: store, runtime: runtime, models: models)
                    }
                }
                if ui.mode == .floating, ui.hasThreads, !ui.minimized {
                    FloatingThread(ui: ui, store: store, runtime: runtime, models: models)
                }
                if ui.showTabs {
                    TabsOverview(browser: browser, ui: ui)
                }
                if ui.showAgents {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AgentsOverview(ui: ui, store: store, models: models, runtime: runtime)
                    }
                }
            }
            .animation(Theme.motion(Theme.grow), value: ui.hasThreads)
            .animation(Theme.motion(Theme.grow), value: ui.minimized)
            .animation(Theme.motion(Theme.morph), value: ui.mode)
            .animation(Theme.motion(Theme.grow), value: ui.showAgents)
            .animation(Theme.motion(Theme.grow), value: ui.showTabs)
            AgentDock(ui: ui, store: store, models: models, runtime: runtime)
        }
        .sheet(isPresented: $ui.showNewAgent) {
            AgentEditor(ui: ui, store: store, models: models, editing: ui.editing)
        }
        .task {
            await models.refresh()
            XoolUI.shared.applyLaunchRequest()
        }
    }
}
