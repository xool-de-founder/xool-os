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

    @ObservedObject private var flight = PanelFlight.shared

    private var panelsOpen: Bool { ui.showAgents || ui.sidebarOpen }
    private var growth: Animation? { Theme.motion(.easeOut(duration: PanelFlight.duration)) }

    var body: some View {
        // The window runs to the bottom (the column too). Page and the right
        // panels are one card (docs/PLAN.md 8, E): the card's ground lies
        // behind them, the page card sits on its left, the panels' content on
        // the rest. The agent row is under the card, flush with its right
        // edge, and leaves the page its room (ContentView: AgentDock.height).
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Theme.surface)
                .padding(.leading, ui.page.leading).padding(.top, ui.page.top)
                .padding(.bottom, AgentDock.height).padding(.trailing, Metrics.cardGap)
                .opacity(panelsOpen ? 1 : 0)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    content
                    if ui.mode == .floating, ui.hasThreads, !ui.minimized {
                        FloatingThread(ui: ui, store: store, runtime: runtime, models: models)
                            .padding(.bottom, AgentDock.height)
                    }
                    // The views that open in the content area lie exactly on the
                    // page's card: the column and the agent row stay in reach.
                    if ui.showTabs {
                        TabsOverview(browser: browser, ui: ui)
                            .modifier(PageFrame(insets: ui.page))
                    }
                    if ui.showBrain {
                        BrainView(ui: ui, browser: browser)
                            .modifier(PageFrame(insets: ui.page))
                            .transition(.opacity)
                    }
                    if ui.showMedia {
                        MediaView(ui: ui, browser: browser)
                            .modifier(PageFrame(insets: ui.page))
                            .transition(.opacity)
                    }
                }
                .overlay { CardJoin(insets: ui.page).opacity(panelsOpen ? 1 : 0) }
                PanelColumn(open: ui.showAgents, width: AgentsOverview.width, top: ui.page.top) {
                    AgentsOverview(ui: ui, store: store, models: models, runtime: runtime, flight: flight)
                }
                PanelColumn(open: ui.sidebarOpen, width: ui.sidebarWidth, top: ui.page.top) {
                    ThreadSidebar(ui: ui, store: store, runtime: runtime, models: models)
                }
            }
            AgentDock(ui: ui, store: store, models: models, runtime: runtime, flight: flight)
            FlightLayer(flight: flight, store: store)
        }
        .coordinateSpace(name: PanelFlight.space)
        .onPreferenceChange(FlightFrames.self) { new in
            MainActor.assumeIsolated { flight.frames.merge(new) { _, fresh in fresh } }
        }
        .onAppear { flight.sync(open: ui.showAgents) }
        .onChange(of: ui.showAgents) { _, open in flight.set(open: open) }
        // Under the title bar's band, as the window's own layers are.
        .ignoresSafeArea(.container, edges: .top)
        .animation(Theme.motion(Theme.grow), value: ui.hasThreads)
        .animation(Theme.motion(Theme.grow), value: ui.minimized)
        .animation(Theme.motion(Theme.morph), value: ui.mode)
        .animation(growth, value: ui.showAgents)
        .animation(growth, value: ui.sidebarOpen)
        .animation(Theme.motion(Theme.grow), value: ui.showTabs)
        .animation(Theme.motion(Theme.grow), value: ui.showBrain)
        .animation(Theme.motion(Theme.grow), value: ui.showMedia)
        .sheet(isPresented: $ui.showNewAgent) {
            AgentEditor(ui: ui, store: store, models: models, editing: ui.editing)
        }
        .task {
            await models.refresh()
            VoiceBridge.shared.install()
            JarvisEntry.shared.install()
            XoolUI.shared.applyLaunchRequest()
        }
    }
}

/// A view laid over the page's card: its insets, its corners.
struct PageFrame: ViewModifier {
    let insets: EdgeInsets
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: insets.leading > 0 && insets.top > 0 && insets.trailing > 0 ? Metrics.cardRadius : 0, style: .continuous))
            .padding(insets)
    }
}
