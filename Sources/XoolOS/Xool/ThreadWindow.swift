import SwiftUI

/// One thread's content: header, messages, input. Used by the floating
/// window and by the column on the right.
struct ThreadView: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var models: ModelStore
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
                AgentAvatar(color: agent.color, size: 22, thinking: thread.map { runtime.thinking.contains($0.id) } ?? false)
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
                ForEach(Self.starters, id: \.self) { text in
                    XoolButton(action: { runtime.send(text, in: thread.id) }) {
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

    @ViewBuilder
    private func bubble(_ message: ChatMessage, _ agent: Agent) -> some View {
        if message.role == .user {
            Text(message.text)
                .font(Theme.body).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.hover))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You: \(message.text)")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text).font(Theme.body).foregroundStyle(Theme.text).textSelection(.enabled)
                } else if message.failed == nil {
                    Text("…").font(Theme.body).foregroundStyle(Theme.textMuted)
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
            if busy {
                XoolIconButton(symbol: "stop.circle", label: "Stop answering") { runtime.stop(thread.id) }
            } else {
                XoolIconButton(symbol: "arrow.up.circle", label: "Send message") { send(thread) }
            }
        }
        .padding(Theme.Space.s)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
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
