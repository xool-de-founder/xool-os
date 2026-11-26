import SwiftUI
import AppKit

/// How threads open: a small floating window, or a column on the right.
enum ThreadMode: String, CaseIterable, Identifiable {
    case floating, sidebar
    var id: String { rawValue }
    var title: String { self == .floating ? "Floating window" : "Sidebar on the right" }
}

/// What is open of Xool's own interface, shared by every window.
@MainActor
final class XoolUI: ObservableObject {
    static let shared = XoolUI()

    static let modeKey = "xool.threadMode"
    static let widthKey = "xool.sidebarWidth"

    @Published var mode: ThreadMode {
        didSet { Store.settings.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var sidebarWidth: CGFloat {
        didSet { Store.settings.set(Double(sidebarWidth), forKey: Self.widthKey) }
    }
    /// Open threads, in the order of their tabs; the one in front.
    @Published private(set) var open: [UUID] = []
    @Published var front: UUID?
    @Published var minimized = false
    @Published var large = false
    @Published var showAgents = false
    @Published var showTabs = false
    @Published var showModels = false
    @Published var creating: Agent.ID?
    @Published var showNewAgent = false
    /// The agent the sheet edits, nil when it makes a new one.
    @Published var editing: Agent?

    init() {
        mode = ThreadMode(rawValue: Store.settings.string(forKey: Self.modeKey) ?? "") ?? .floating
        let w = Store.settings.double(forKey: Self.widthKey)
        sidebarWidth = w >= 320 ? CGFloat(w) : 400
    }

    /// Clicking an agent: its last thread, or a new one.
    func openAgent(_ id: UUID, fresh: Bool = false) {
        let store = AgentStore.shared
        let thread = (fresh ? nil : store.lastThread(of: id)) ?? store.newThread(for: id)
        openThread(thread.id)
    }

    func openThread(_ id: UUID) {
        if !open.contains(id) { open.append(id) }
        front = id
        minimized = false
        showAgents = false
        withAnimation(Theme.motion(Theme.grow)) { objectWillChange.send() }
    }

    func close(_ id: UUID) {
        ChatRuntime.shared.stop(id)
        open.removeAll { $0 == id }
        if front == id { front = open.last }
        if open.isEmpty { minimized = false; large = false }
    }

    func toggleMode() {
        withAnimation(Theme.motion(Theme.morph)) {
            mode = mode == .floating ? .sidebar : .floating
        }
    }

    var hasThreads: Bool { !open.isEmpty }
    /// The sidebar takes room from the page only while it is open.
    var sidebarOpen: Bool { mode == .sidebar && hasThreads && !minimized }

    func toggleAgents() { showAgents.toggle(); if showAgents { showTabs = false } }
    func toggleTabs() { showTabs.toggle(); if showTabs { showAgents = false } }

    /// ⌥1–⌥9: the agent at that place in the bar.
    func openAgent(number: Int) {
        let pinned = AgentStore.shared.agents
        guard number >= 1, number <= pinned.count else { return }
        openAgent(pinned[number - 1].id)
    }
}

// MARK: - launch requests for screenshots and checks

extension XoolUI {
    /// `XOOL_UI=thread:1,send:Hello` opens the first agent's thread and asks
    /// it; also `agents`, `tabs`, `models`, `sidebar`, `new`, `light`, `dark`.
    /// Only read at launch, to put the interface in a state without a pointer.
    func applyLaunchRequest() {
        guard let raw = getenv("XOOL_UI").map({ String(cString: $0) }), !raw.isEmpty else { return }
        for part in raw.split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            switch pieces[0] {
            case "thread":
                let index = max(0, (Int(pieces.count > 1 ? pieces[1] : "1") ?? 1) - 1)
                let agents = AgentStore.shared.agents
                if index < agents.count { openAgent(agents[index].id) }
            case "send":
                if let id = front, pieces.count > 1 { ChatRuntime.shared.send(pieces[1], in: id) }
            case "agents": showAgents = true
            case "tabs": showTabs = true
            case "models": showModels = true
            case "settings":
                Browsers.frontBrowser.settingsPage = SettingsPanel.Page.named(pieces.count > 1 ? pieces[1] : "models") ?? .models
                Browsers.frontBrowser.tuning = true
            case "new": editing = nil; showNewAgent = true
            case "sidebar": mode = .sidebar
            case "floating": mode = .floating
            // Test runs only (SEARCH_PROBE): a stand-in provider, a made-up key,
            // a chosen model, the cloud switch. Same rules as bench's ai verbs.
            case "mock" where Store.testing:
                if let url = pieces.count > 1 ? URL(string: pieces[1]) : nil, ["127.0.0.1", "localhost"].contains(url.host() ?? "") { AIProvider.mock = url }
            case "key" where Store.testing:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
                if k.count == 2, let provider = AIProvider(rawValue: k[0]) { _ = AIKeys.save(k[1], for: provider) }
            case "choose" where Store.testing:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
                if k.count == 2 { ModelStore.shared.current = ModelChoice(provider: k[0], model: k[1]) }
            // Test runs only: the agent role's model, what a question about a
            // site is answered (after four seconds), and Stop after n seconds.
            case "role" where Store.testing:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "=", maxSplits: 1).map(String.init)
                if k.count == 2, let role = ModelRole(rawValue: k[0]) {
                    let m = k[1].split(separator: "/", maxSplits: 1).map(String.init)
                    if m.count == 2 { ModelRouter.shared.set(ModelChoice(provider: m[0], model: m[1]), for: role) }
                }
            case "site" where Store.testing:
                AgentRuntime.shared.autoAnswer = pieces.count > 1 ? ["always": .always, "run": .thisRun, "deny": .deny][pieces[1]] : nil
            case "stopafter" where Store.testing:
                let seconds = Double(pieces.count > 1 ? pieces[1] : "") ?? 10
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    FileHandle.standardError.write(Data("stopafter: fired, front=\(String(describing: self?.front))\n".utf8))
                    if let id = self?.front { ChatRuntime.shared.stop(id) }
                }
            // Test runs only: a WAV file in place of the microphone, said to the front agent.
            case "voicewav" where Store.testing:
                if pieces.count > 1 { VoiceBridge.shared.feed(file: URL(fileURLWithPath: pieces[1])) }
            case "voiceinterrupt" where Store.testing:
                let seconds = Double(pieces.count > 1 ? pieces[1] : "") ?? 5
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { VoiceBridge.shared.interrupt() }
            case "cloud" where Store.testing: ModelRouter.shared.allowCloud = pieces.count > 1 && pieces[1] == "on"
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
    }
}
