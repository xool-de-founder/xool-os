import SwiftUI

/// One thread's content: header, messages, input. Used by the floating
/// window and by the column on the right.
struct ThreadView: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var models: ModelStore
    @ObservedObject private var voice = VoiceBridge.shared
    let docked: Bool
    @XState private var draft = ""
    @FocusState private var typing: Bool

    private var thread: ChatThread? { ui.front.flatMap { store.thread($0) } }
    private var agent: Agent? { thread.flatMap { store.agent($0.agentID) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if ui.open.count > 1 { tabs }
            Theme.line.frame(height: 1)
            if let thread, let agent {
                messages(thread, agent)
                if let ask = runtime.asking[thread.id] {
                    SiteQuestion(ask: ask, agent: agent, thread: thread.id)
                }
                slashMenu(agent)
                mentionMenu
                voiceNote(thread, agent)
                composer(thread, agent)
            } else {
                Spacer()
            }
        }
        .padding(.top, docked ? 28 : 0)
        .background(Theme.raised)
        .onAppear { typing = true }
        .onChange(of: ui.front) { _, _ in typing = true }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if let agent {
                AgentAvatar(color: agent.color, size: 22, thinking: thread.map { runtime.thinking.contains($0.id) || runtime.activity[$0.id] == .thinking } ?? false)
                Text(agent.name).font(Theme.heading).foregroundStyle(Theme.text).lineLimit(1)
                Text(models.resolve(agent)?.label ?? "No model")
                    .font(Theme.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
            XoolIconButton(symbol: "minus", label: "Minimize thread") {
                withAnimation(Theme.motion(Theme.grow)) { ui.minimized = true }
            }
            XoolIconButton(symbol: docked ? "rectangle.on.rectangle" : "sidebar.right",
                           label: docked ? "Open as floating window" : "Dock as sidebar") { ui.toggleMode() }
            if !docked {
                XoolIconButton(symbol: ui.large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: ui.large ? "Smaller" : "Larger") {
                    withAnimation(Theme.motion(Theme.grow)) { ui.large.toggle() }
                }
            }
            XoolIconButton(symbol: "xmark", label: "Close thread") {
                if let id = ui.front { withAnimation(Theme.motion(Theme.grow)) { ui.close(id) } }
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: 40)
        .background(agent?.color.bg ?? Color.clear)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(ui.open, id: \.self) { id in
                    if let t = store.thread(id), let a = store.agent(t.agentID) {
                        XoolButton(radius: Theme.Radius.chip, action: { ui.front = id }) {
                            HStack(spacing: 5) {
                                AgentAvatar(color: a.color, size: 14)
                                Text(a.name).font(Theme.caption).foregroundStyle(Theme.text)
                            }
                            .padding(.horizontal, 6)
                            .background(ui.front == id ? Theme.hover : Color.clear)
                        }
                        .accessibilityLabel("Thread with \(a.name)")
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s)
        }
        .frame(height: 30)
    }

    // MARK: messages

    @ViewBuilder
    private func messages(_ thread: ChatThread, _ agent: Agent) -> some View {
        if thread.messages.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Spacer()
                Text("Ask \(agent.name) something").font(Theme.heading).foregroundStyle(Theme.text)
                ForEach(starters(agent), id: \.self) { text in
                    XoolButton(action: { if text.hasPrefix("/") { draft = text + " "; typing = true } else { runtime.send(text, in: thread.id) } }) {
                        Text(text).font(Theme.body).foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(thread.messages) { message in
                            bubble(message, agent).id(message.id)
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .onChange(of: thread.messages.last?.text) { _, _ in
                    if let last = thread.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear { if let last = thread.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    static let starters = ["What can you help me with?", "Explain this like I'm new to it", "Draft a short reply for me"]

    /// Three suggestions: the agent's own skills first.
    private func starters(_ agent: Agent) -> [String] {
        let skills = SkillStore.shared.skills(for: agent).prefix(3).map { "/" + $0.name }
        return Array((skills + Self.starters).prefix(3))
    }

    // MARK: skills

    /// `/` at the start of the input: the agent's skills, narrowed as you type.
    @ViewBuilder
    private func slashMenu(_ agent: Agent) -> some View {
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) {
            let typed = Skill.slug(String(draft.dropFirst()))
            let found = SkillStore.shared.skills(for: agent).filter { typed.isEmpty || $0.name.hasPrefix(typed) }
            VStack(alignment: .leading, spacing: 0) {
                if found.isEmpty {
                    Text(SkillStore.shared.skills(for: agent).isEmpty ? "No skills on this agent yet. Add some when you edit it." : "No skill starts with that.")
                        .font(Theme.small).foregroundStyle(Theme.textMuted).padding(Theme.Space.s)
                }
                ForEach(found.prefix(6)) { skill in
                    XoolButton(action: { draft = "/" + skill.name + " "; typing = true }) {
                        HStack(spacing: Theme.Space.s) {
                            Text("/" + skill.name).font(Theme.label).foregroundStyle(Theme.text)
                            Text(skill.description).font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("Skill \(skill.name). \(skill.description)")
                }
            }
            .padding(Theme.Space.xs)
            .background(Theme.surface)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
    }

    // MARK: mentions

    /// The word being typed at the end of the input, if it starts with `@`.
    private var mentioning: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains("\n") || word.contains("](") ? nil : String(word)
    }

    /// `@` in the input: entries of the Brain, narrowed as you type; one
    /// picked is put in the message as a link the agent can read.
    @ViewBuilder
    private var mentionMenu: some View {
        if let typed = mentioning {
            let found = typed.isEmpty ? Array(BrainStore.shared.items.filter { $0.kind != .bookmark }.prefix(6))
                : BrainStore.shared.db.titles(matching: typed, limit: 6)
            VStack(alignment: .leading, spacing: 0) {
                if found.isEmpty {
                    Text(BrainStore.shared.items.isEmpty ? "The Brain is empty. Drop files on “Brain” in the sidebar." : "No Brain entry has that in its title.")
                        .font(Theme.small).foregroundStyle(Theme.textMuted).padding(Theme.Space.s)
                }
                ForEach(found) { entry in
                    XoolButton(action: { mention(entry) }) {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: entry.kind.symbol).font(.system(size: 11)).foregroundStyle(Theme.textMuted).frame(width: 14)
                            Text(entry.title).font(Theme.label).foregroundStyle(Theme.text).lineLimit(1)
                            Text(entry.kind.one).font(Theme.small).foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("Mention \(entry.kind.one) \(entry.title)")
                }
            }
            .padding(Theme.Space.xs)
            .background(Theme.surface)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
    }

    private func mention(_ entry: BrainItem) {
        guard let at = draft.lastIndex(of: "@") else { return }
        let name = entry.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        draft = String(draft[..<at]) + "[@\(name)](\(entry.address)) "
        typing = true
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, _ agent: Agent) -> some View {
        if message.role == .user {
            BrainText(text: message.text)
                .font(Theme.body).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.hover))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You: \(message.text)")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let steps = message.steps, !steps.isEmpty {
                    StepLog(steps: steps, color: agent.color)
                }
                if !message.text.isEmpty {
                    BrainText(text: message.text).font(Theme.body).foregroundStyle(Theme.text).textSelection(.enabled)
                } else if message.failed == nil, message.steps?.isEmpty != false {
                    Text("…").font(Theme.body).foregroundStyle(Theme.textMuted)
                }
                if let model = message.model, !message.text.isEmpty {
                    Text(model).font(Theme.caption).foregroundStyle(Theme.faint)
                }
                if let failed = message.failed {
                    Label(failed, systemImage: "exclamationmark.triangle")
                        .font(Theme.small).foregroundStyle(Theme.text)
                        .padding(Theme.Space.s)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.hover))
                }
            }
            .padding(.leading, Theme.Space.s)
            .overlay(alignment: .leading) { Rectangle().fill(agent.color.solid).frame(width: 2) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(agent.name): \(message.text)")
        }
    }

    // MARK: input

    private func composer(_ thread: ChatThread, _ agent: Agent) -> some View {
        let busy = runtime.thinking.contains(thread.id)
        return HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Message \(agent.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...5)
                .focused($typing)
                .onSubmit { send(thread) }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(typing ? Theme.focus : Theme.line, lineWidth: typing ? 2 : 1))
                .accessibilityLabel("Message \(agent.name)")
            micButton(thread, agent)
            if busy {
                XoolIconButton(symbol: "stop.circle", label: "Stop answering") { runtime.stop(thread.id); voice.interrupt() }
            } else {
                XoolIconButton(symbol: "arrow.up.circle", label: "Send message") { send(thread) }
            }
        }
        .padding(Theme.Space.s)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    // MARK: voice

    /// Dictation into the field: click, speak, click again (Esc cancels). The
    /// same waveform as the address field. Talking to the agent itself is
    /// still holding `fn`; right-click: hands-free, where you just talk.
    private func micButton(_ thread: ChatThread, _ agent: Agent) -> some View {
        DictationButton(deliver: { text in
            draft = draft.isEmpty ? text : draft + (draft.hasSuffix(" ") ? "" : " ") + text
            typing = true
        })
        .contextMenu {
            Button(voice.handsFree ? "Stop hands-free" : "Talk hands-free") { voice.toggleHandsFree() }
        }
    }

    /// What the voice needs the user to know: loading, no microphone, no setup.
    @ViewBuilder
    private func voiceNote(_ thread: ChatThread, _ agent: Agent) -> some View {
        if let note = voice.notice {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "mic.slash").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Text(note.text).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let url = note.settings {
                    XoolButton(action: { NSWorkspace.shared.open(url) }) {
                        Text("Open Settings").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.s)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                }
                XoolIconButton(symbol: "xmark", label: "Dismiss") { voice.notice = nil }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
            .background(Theme.surface)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        } else if let loading = voice.loading {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(loading).font(Theme.small).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
            .background(Theme.surface)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        } else if voice.state != .idle, voice.target == thread.id {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: voice.state == .speaking ? "speaker.wave.2" : voice.state == .listening ? "waveform" : "ellipsis")
                    .font(.system(size: 11)).foregroundStyle(agent.color.solid)
                Text(voice.state == .listening ? "Listening…" : voice.state == .speaking ? "Speaking. Talk or press a key to interrupt" : "Thinking…")
                    .font(Theme.small).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            .accessibilityElement(children: .combine)
        }
    }

    private func send(_ thread: ChatThread) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        runtime.send(text, in: thread.id)
    }
}

/// The small floating window, bottom right: 380 × 520, over the page.
struct FloatingThread: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var models: ModelStore

    private var agent: Agent? { ui.front.flatMap { store.thread($0) }.flatMap { store.agent($0.agentID) } }

    var body: some View {
        ThreadView(ui: ui, store: store, runtime: runtime, models: models, docked: false)
            .frame(width: ui.large ? 560 : 380, height: ui.large ? 680 : 520)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                .strokeBorder(agent?.color.solid.opacity(0.7) ?? Theme.line, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .padding(Theme.Space.l)
            .transition(Motion.reduced ? .identity
                : .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
    }
}

/// The same thread as a column on the right, 400 pt, pulled wider or
/// narrower by its left edge. The page moves over instead of being covered.
struct ThreadSidebar: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var models: ModelStore
    @XState private var startWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Theme.line.frame(width: 1)
                .overlay(
                    Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = ui.sidebarWidth }
                                ui.sidebarWidth = min(640, max(320, (startWidth ?? 400) - value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil })
                        .accessibilityLabel("Resize thread sidebar")
                )
            ThreadView(ui: ui, store: store, runtime: runtime, models: models, docked: true)
        }
        .frame(width: ui.sidebarWidth)
        .transition(Motion.reduced ? .identity : .move(edge: .trailing).combined(with: .opacity))
    }
}

// MARK: - what the agent does

/// The agent's steps in the thread: "Opens example.com", "Clicks Next", each
/// a line that takes you to the tab it happened in.
struct StepLog: View {
    let steps: [AgentStep]
    let color: AgentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in StepRow(step: step, color: color) }
        }
        .padding(.bottom, 4)
    }
}

struct StepRow: View {
    let step: AgentStep
    let color: AgentColor

    private var symbol: String {
        switch step.kind {
        case .search: return "magnifyingglass"
        case .open: return "arrow.up.right.square"
        case .read: return "doc.text"
        case .click: return "cursorarrow.click"
        case .type: return "keyboard"
        case .wait: return "hourglass"
        case .back: return "chevron.backward"
        case .skill: return "wand.and.stars"
        case .brain: return "brain"
        case .other: return "wrench"
        }
    }

    private var jumps: Bool { step.tab != nil || step.url != nil }

    var body: some View {
        XoolButton(radius: Theme.Radius.chip, action: { AgentJump.go(step) }) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color.solid).frame(width: 14)
                Text(step.text).font(Theme.small)
                    .foregroundStyle(step.state == .failed ? Theme.textMuted : Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                switch step.state {
                case .running: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14, height: 14)
                case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        }
        .disabled(!jumps)
        .frame(minHeight: 22)
        .help(step.note ?? (jumps ? "Go to this tab" : step.text))
        .accessibilityLabel("\(step.text), \(step.state == .running ? "running" : step.state == .done ? "done" : "failed")")
        .accessibilityHint(jumps ? "Goes to its tab" : "")
    }
}

/// A step's tab, or its page where the tab is gone.
@MainActor
enum AgentJump {
    static func go(_ step: AgentStep) {
        if let id = step.tab {
            for browser in Browsers.all {
                if let tab = browser.tabs.first(where: { $0.id == id }) {
                    browser.window?.makeKeyAndOrderFront(nil)
                    browser.select(tab)
                    return
                }
            }
        }
        if let text = step.url, let url = URL(string: text) {
            if let entry = BrainStore.id(from: url) { BrainStore.shared.show(entry) }
            else if ["http", "https"].contains(url.scheme ?? "") { Browsers.frontBrowser.open(url, foreground: true) }
        }
    }
}

/// "<agent> wants to use example.com": Allow (kept for this agent), only for
/// this run, or Deny. The agent waits for the answer.
struct SiteQuestion: View {
    let ask: SitePermission
    let agent: Agent
    let thread: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                AgentAvatar(color: agent.color, size: 18)
                Text("\(agent.name) wants to use \(ask.host)")
                    .font(Theme.label).foregroundStyle(Theme.text).lineLimit(2)
            }
            Text("It reads and clicks in a tab of its own that you can watch. It never types passwords, cards or codes.")
                .font(Theme.small).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                XoolButton(action: { AgentRuntime.shared.resolve(thread, .always) }) {
                    Text("Always allow").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.s)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(agent.color.solid))
                XoolButton(action: { AgentRuntime.shared.resolve(thread, .thisRun) }) {
                    Text("This run only").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.s)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                Spacer(minLength: 0)
                XoolButton(action: { AgentRuntime.shared.resolve(thread, .deny) }) {
                    Text("Don't allow").font(Theme.label).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.s)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(agent.color.bg)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.name) asks to use \(ask.host)")
    }
}
