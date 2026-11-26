import SwiftUI

/// The panel from the right: pinned agents large, then every agent by latest
/// activity with its last line, and the default model at the foot.
struct AgentsOverview: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    @ObservedObject var runtime: ChatRuntime
    @XState private var query = ""

    private var list: [Agent] {
        store.byActivity.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("Agents").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                XoolIconButton(symbol: "plus", label: "New agent") { ui.editing = nil; ui.showNewAgent = true }
                XoolIconButton(symbol: "xmark", label: "Close agents overview") { ui.showAgents = false }
            }
            .padding(.leading, Theme.Space.l).padding(.trailing, Theme.Space.xs).padding(.top, 36)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                TextField("Search agents", text: $query).textFieldStyle(.plain).font(Theme.body)
                    .accessibilityLabel("Search agents")
            }
            .padding(.horizontal, Theme.Space.m).frame(height: Theme.target)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)

            if store.agents.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("No agents yet").font(Theme.heading).foregroundStyle(Theme.text)
                    Text("An agent has a name, a colour, a model and instructions. Make the first one.")
                        .font(Theme.body).foregroundStyle(Theme.textMuted)
                    XoolButton(action: { ui.editing = nil; ui.showNewAgent = true }) {
                        Label("Create an agent", systemImage: "plus").font(Theme.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Space.m)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                }
                .padding(Theme.Space.l)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        let pinned = store.agents.filter(\.pinned)
                        if !pinned.isEmpty && query.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                                ForEach(pinned) { agent in
                                    XoolButton(action: { ui.openAgent(agent.id) }) {
                                        VStack(spacing: 6) {
                                            AgentAvatar(color: agent.color, size: 44,
                                                        thinking: runtime.isThinking(agent: agent.id))
                                            Text(agent.name).font(Theme.small).foregroundStyle(Theme.text).lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                        .padding(.vertical, Theme.Space.s).frame(maxWidth: .infinity)
                                    }
                                    .accessibilityLabel(agent.name)
                                }
                            }
                        }
                        ForEach(list) { agent in row(agent) }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.s)
                }
            }
            Theme.line.frame(height: 1)
            HStack(spacing: Theme.Space.s) {
                Image(systemName: models.current?.isLocal == false ? "circle" : "circle.fill")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textMuted)
                Text("You · \(models.current.map { ($0.isLocal ? "local: " : "cloud: ") + $0.label } ?? "no model")")
                    .font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
                Spacer()
            }
            .padding(Theme.Space.m)
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(Theme.raised)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
        .transition(Motion.reduced ? .identity : .move(edge: .trailing).combined(with: .opacity))
    }

    private func row(_ agent: Agent) -> some View {
        let last = store.lastThread(of: agent.id)
        return XoolButton(action: { ui.openAgent(agent.id) }) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                AgentAvatar(color: agent.color, size: 28, thinking: runtime.isThinking(agent: agent.id))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.label).foregroundStyle(Theme.text)
                    Text(last?.lastLine ?? "No messages yet").font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(agent.name). \(last?.lastLine ?? "No messages yet")")
        .contextMenu {
            Button("Edit agent…") { ui.editing = agent; ui.showNewAgent = true }
            Button(agent.pinned ? "Remove from bar" : "Show in bar") { store.setPinned(agent.id, !agent.pinned) }
            Button("Delete agent", role: .destructive) { store.remove(agent.id) }
        }
    }
}

/// Make or edit an agent: name, colour, model, instructions.
struct AgentEditor: View {
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    let editing: Agent?
    @XState private var name = ""
    @XState private var color: AgentColor = .green
    @XState private var instructions = ""
    @XState private var model: ModelChoice?
    @XState private var picking = false
    @FocusState private var nameFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(editing == nil ? "New agent" : "Edit agent").font(Theme.title).foregroundStyle(Theme.text)
            HStack(spacing: Theme.Space.m) {
                AgentAvatar(color: color, size: 40)
                TextField("Name", text: $name).textFieldStyle(.plain).font(Theme.heading).focused($nameFocus)
                    .padding(.horizontal, Theme.Space.m).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(nameFocus ? Theme.focus : Theme.line, lineWidth: nameFocus ? 2 : 1))
                    .accessibilityLabel("Agent name")
            }
            HStack(spacing: Theme.Space.s) {
                ForEach(AgentColor.allCases) { option in
                    XoolButton(radius: 8, action: { color = option }) {
                        Circle().fill(option.solid).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: color == option ? 2 : 0).padding(-3))
                            .frame(width: Theme.target, height: Theme.target)
                    }
                    .accessibilityLabel("\(option.name)\(color == option ? ", selected" : "")")
                }
            }
            HStack {
                Text("Model").font(Theme.small).foregroundStyle(Theme.textMuted)
                Spacer()
                XoolButton(action: { picking = true }) {
                    Text(model.map(\.label) ?? "Follow the bar's model").font(Theme.small).foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.s)
                }
                .popover(isPresented: $picking) {
                    VStack(spacing: 0) {
                        XoolButton(action: { model = nil; picking = false }) {
                            Text("Follow the bar's model").font(Theme.body).padding(.horizontal, Theme.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        ModelPicker(models: models, ui: ui, onPick: { model = $0; picking = false })
                    }
                    .frame(width: 300)
                }
            }
            Text("Instructions").font(Theme.small).foregroundStyle(Theme.textMuted)
            TextEditor(text: $instructions)
                .font(Theme.body).scrollContentBackground(.hidden)
                .padding(Theme.Space.s).frame(height: 110)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                .accessibilityLabel("Instructions")
            HStack {
                Spacer()
                XoolButton(action: { ui.showNewAgent = false }) {
                    Text("Cancel").font(Theme.label).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.m)
                }
                XoolButton(action: save) {
                    Text(editing == nil ? "Create" : "Save").font(Theme.label).foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.m)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 420)
        .background(Theme.raised)
        .onAppear {
            if let editing {
                name = editing.name; color = editing.color; instructions = editing.instructions; model = editing.model
            } else {
                color = store.nextColor()
            }
            nameFocus = true
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var agent = editing {
            agent.name = trimmed; agent.color = color; agent.instructions = instructions; agent.model = model
            store.update(agent)
        } else {
            store.add(name: trimmed, color: color, instructions: instructions, model: model)
        }
        ui.showNewAgent = false
    }
}
