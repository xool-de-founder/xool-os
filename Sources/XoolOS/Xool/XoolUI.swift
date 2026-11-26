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
    @Published var showBrain = false
    @Published var showMedia = false
    @Published var showKeys = false
    /// Where the page's card lies in the window (ContentView sets it): the
    /// views that open in the content area (Brain, Media, Tabs) sit exactly there.
    @Published var page = EdgeInsets()
    /// When the shortcuts popover last closed, so the button that closed it
    /// (a click outside) does not open it again.
    private var keysClosedAt = Date.distantPast
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

    func hasThread(_ id: UUID) -> Bool { AgentStore.shared.thread(id) != nil }

    func openThread(_ id: UUID) {
        if !open.contains(id) { open.append(id) }
        front = id
        minimized = false
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

    /// The agents panel sits beside the page, so it does not close the views.
    func toggleAgents() { showAgents.toggle() }
    func toggleTabs() { showTabs.toggle(); if showTabs { showBrain = false; showMedia = false } }
    func toggleBrain() {
        showBrain.toggle()
        if showBrain { showTabs = false; showMedia = false }
    }
    func toggleMedia() {
        showMedia.toggle()
        if showMedia { showTabs = false; showBrain = false }
    }
    /// Brain, Media and the tab overview put away: whatever opens next is seen.
    func closeViews() {
        if showTabs { showTabs = false }
        if showBrain { showBrain = false }
        if showMedia { showMedia = false }
    }

    func toggleKeys() {
        if showKeys { showKeys = false } else if Date().timeIntervalSince(keysClosedAt) > 0.25 { showKeys = true }
    }
    func closeKeys() { if showKeys { showKeys = false; keysClosedAt = Date() } }

    /// ⌥1–⌥9: the agent at that place in the bar.
    func openAgent(number: Int) {
        // Jarvis first, then his assistants, then the rest.
        let store = AgentStore.shared
        let order = [store.jarvis] + store.assistants + store.further
        guard number >= 1, number <= order.count else { return }
        openAgent(order[number - 1].id)
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
            // Test and profile runs only: the overview toggled after n seconds
            // (a picture sequence of the flight), and ⌘T's new tab.
            case "agentstoggle" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let seconds = Double(pieces.count > 1 ? pieces[1] : "") ?? 4
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.toggleAgents() }
            case "tabs": showTabs = true
            case "models": showModels = true
            case "brain": showBrain = true
            case "media": showMedia = true
            case "keys": showKeys = true
            // Test and profile runs only: put files in the Brain, a search in
            // its field, an entry on show, or write what a search finds to a file.
            case "brainadd" where Store.testing || getenv("XOOL_PROFILE") != nil:
                if pieces.count > 1 { BrainStore.shared.add(pieces[1].split(separator: ";").map { URL(fileURLWithPath: String($0)) }) }
            case "brainq" where Store.testing || getenv("XOOL_PROFILE") != nil:
                BrainStore.shared.launchQuery = pieces.count > 1 ? pieces[1] : ""
            // The window's own drawing to a PNG after n seconds, for a screen
            // that can't be captured (asleep, locked): snapshot:<seconds>|<path>.
            case "snapshot" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 1).map(String.init)
                if k.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 5)) {
                        guard let view = Browsers.frontBrowser.window?.contentView,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let out = URL(fileURLWithPath: k[1])
                        // A web view (the canvas) does not draw into cacheDisplay: its own snapshot is laid over.
                        let webs = CanvasHosts.shared.live.values.map(\.webView).filter { $0.window === view.window && !$0.isHiddenOrHasHiddenAncestor }
                        guard let web = webs.first else {
                            try? rep.representation(using: .png, properties: [:])?.write(to: out)
                            return
                        }
                        web.takeSnapshot(with: nil) { image, _ in
                            let base = NSImage(size: view.bounds.size)
                            base.addRepresentation(rep)
                            let frame = view.convert(web.bounds, from: web)
                            let y = view.isFlipped ? view.bounds.height - frame.maxY : frame.minY
                            let composed = NSImage(size: view.bounds.size, flipped: false) { _ in
                                base.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                                image?.draw(in: NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
                                return true
                            }
                            if let tiff = composed.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                                try? png.write(to: out)
                            }
                        }
                    }
                }
            case "brainlog" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 1).map(String.init)
                if k.count == 2 { BrainStore.shared.logSearch(k[1], to: k[0]) }
            // Test and profile runs only: canvases. `canvasnew` makes and opens an empty one;
            // `canvasagent` makes one the way an agent's tools do; `canvasopen:<id or title>`;
            // `canvasjs:<seconds>|<script file>|<result file>` runs a script in the open page.
            case "canvasnew" where Store.testing || getenv("XOOL_PROFILE") != nil:
                CanvasStore.shared.newCanvas()
            case "canvasagent" where Store.testing || getenv("XOOL_PROFILE") != nil:
                CanvasStore.shared.launchDemo()
            case "canvasopen" where Store.testing || getenv("XOOL_PROFILE") != nil:
                if pieces.count > 1, let id = AgentTools.canvasID(pieces[1]) { CanvasStore.shared.open(id) }
            case "canvasjs" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 2).map(String.init)
                if k.count == 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 5)) {
                        guard let controller = CanvasHosts.shared.live.values.first,
                              let script = try? String(contentsOfFile: k[1], encoding: .utf8) else { return }
                        controller.run(script) { try? $0.write(toFile: k[2], atomically: true, encoding: .utf8) }
                    }
                }
            // Test and profile runs only: a key pressed in the front window, as
            // the keyboard does it, after n seconds, then the tab count and the
            // active tab's address written to a file: keyevent:<seconds>|<key>|<result file>
            // (key: "cmd-t", "opt-cmd-j" …).
            case "keyevent" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 2).map(String.init)
                if k.count == 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 4)) {
                        let parts = k[1].split(separator: "-").map(String.init)
                        var flags: NSEvent.ModifierFlags = []
                        for m in parts.dropLast() {
                            switch m { case "cmd": flags.insert(.command); case "opt": flags.insert(.option); case "shift": flags.insert(.shift); case "ctrl": flags.insert(.control); default: break }
                        }
                        let key = parts.last ?? "t"
                        let codes: [String: UInt16] = ["t": 17, "j": 38, "n": 45, "k": 40]
                        let window = Browsers.frontBrowser.window
                        let before = Browsers.frontBrowser.tabs.count
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                                                        isARepeat: false, keyCode: codes[key] ?? 17) {
                            NSApp.sendEvent(event)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let b = Browsers.frontBrowser
                            let line = "key \(k[1]): tabs \(before) -> \(b.tabs.count); active blank=\(b.active?.isBlank ?? false); responder=\(String(describing: b.window?.firstResponder))\n"
                            try? line.write(toFile: k[2], atomically: true, encoding: .utf8)
                        }
                    }
                }
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
            // Test and profile runs only: Jarvis' entries. `jarvislisten` is a click on
            // the menu-bar icon; `jarvisfeed:<wav>` says a WAV file to him; `jarvisstatus:<s>|<file>`
            // writes whether the global key and the icon are in place.
            case "jarvislisten" where Store.testing || getenv("XOOL_PROFILE") != nil:
                VoiceBridge.shared.listenToJarvis()
            case "jarvisfeed" where Store.testing || getenv("XOOL_PROFILE") != nil:
                if pieces.count > 1 { VoiceBridge.shared.feedJarvis(file: URL(fileURLWithPath: pieces[1])) }
            // `jarvisfree[open]:<wav>`: as in a conversation, unaddressed (the session closed, or `open`);
            // `voicesave:<seconds>|<wav>`: after a while, the recording of what Jarvis said.
            case "jarvisfree" where Store.testing || getenv("XOOL_PROFILE") != nil, "jarvisfreeopen" where Store.testing || getenv("XOOL_PROFILE") != nil:
                if pieces.count > 1 { VoiceBridge.shared.feedConversation(file: URL(fileURLWithPath: pieces[1]), open: pieces[0] == "jarvisfreeopen") }
            // `voicemic:<seconds>|<wav>`: the fake microphone hears this file after that long.
            case "voicemic" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 1).map(String.init)
                if k.count == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 5)) { VoiceBridge.shared.feedMic(k[1], delay: 0) } }
            // Test runs: the "Set up the voice" button, pressed.
            case "voicesetup" where Store.testing || getenv("XOOL_PROFILE") != nil:
                LocalSetup.shared.start(onlyVoice: true)
            case "voicesave" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 1).map(String.init)
                if k.count == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 20)) { VoiceBridge.shared.saveOutput(to: k[1]) } }
            case "jarvisstatus" where Store.testing || getenv("XOOL_PROFILE") != nil:
                let k = (pieces.count > 1 ? pieces[1] : "").split(separator: "|", maxSplits: 1).map(String.init)
                if k.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(k[0]) ?? 4)) {
                        let entry = JarvisEntry.shared
                        let frame = entry.statusButton.flatMap { $0.window?.frame }.map { "\($0)" } ?? "none"
                        let line = "hotkey set=\(VoiceHotKey.isSet) key=\(entry.choice.combo.display) refusal=\(entry.refusal ?? "none") statusitem=\(entry.statusButton != nil) frame=\(frame)\n"
                        try? line.write(toFile: k[1], atomically: true, encoding: .utf8)
                    }
                }
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
