import SwiftUI

/// The panel from the right, beside the page (it pushes it, never covers
/// it): pinned agents large with their names, then every agent with its
/// last line. No profile row (docs/PLAN.md 6, C).
struct AgentsOverview: View {
    static let width: CGFloat = 300
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    @ObservedObject var runtime: ChatRuntime

    /// The agent whose thread is in front: its tile is raised.
    private var activeAgent: UUID? { ui.front.flatMap { store.thread($0)?.agentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Text("Agents").font(Theme.label).foregroundStyle(Theme.textMuted)
                Spacer()
                XoolIconButton(symbol: "plus", label: "New agent") { ui.editing = nil; ui.showNewAgent = true }
                XoolIconButton(symbol: "xmark", label: "Close agents overview") { ui.showAgents = false }
            }
            .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.top, Theme.Space.s)

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
                        if !pinned.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.xs), count: 3), spacing: Theme.Space.xs) {
                                ForEach(pinned) { agent in
                                    Button { ui.openAgent(agent.id) } label: {
                                        VStack(spacing: 6) {
                                            AgentAvatar(color: agent.color, size: 48,
                                                        thinking: runtime.isThinking(agent: agent.id))
                                            Text(agent.name).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                                        }
                                        .padding(.vertical, Theme.Space.s).frame(maxWidth: .infinity)
                                        .background(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                                            .fill(activeAgent == agent.id ? Theme.raised : Color.clear))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .xoolFocus(radius: Theme.Radius.popover) { ui.openAgent(agent.id) }
                                    .accessibilityLabel(agent.name)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.byActivity) { agent in row(agent) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
        .transition(Motion.reduced ? .identity : .move(edge: .trailing).combined(with: .opacity))
        // Esc closes it.
        .onExitCommand { ui.showAgents = false }
    }

    private func row(_ agent: Agent) -> some View {
        let last = store.lastThread(of: agent.id)
        return XoolButton(action: { ui.openAgent(agent.id) }) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                AgentAvatar(color: agent.color, size: 28, thinking: runtime.isThinking(agent: agent.id))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.label).foregroundStyle(Theme.text)
                    Text(last?.lastLine ?? "No messages yet").font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
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
    @XState private var skillNames: Set<String> = []
    @ObservedObject private var skillStore = SkillStore.shared
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
            skillsSection
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
                skillNames = Set(editing.skills ?? [])
            } else {
                color = store.nextColor()
            }
            nameFocus = true
        }
    }

    /// The skills in `Application Support/Xool/skills`, each ticked or not.
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Skills").font(Theme.small).foregroundStyle(Theme.textMuted)
                Spacer()
                XoolButton(action: {
                    NSWorkspace.shared.open(skillStore.folder)
                }) {
                    Text("Open folder").font(Theme.small).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.s)
                }
                XoolButton(action: { skillStore.reload() }) {
                    Text("Reload").font(Theme.small).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.s)
                }
            }
            if skillStore.skills.isEmpty {
                Text("None yet. Put a folder with a SKILL.md in the skills folder, then Reload. The agent's thread calls one with /.")
                    .font(Theme.small).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(skillStore.skills) { skill in
                    Toggle(isOn: Binding(get: { skillNames.contains(skill.name) },
                                         set: { on in if on { skillNames.insert(skill.name) } else { skillNames.remove(skill.name) } })) {
                        HStack(spacing: Theme.Space.s) {
                            Text("/" + skill.name).font(Theme.label).foregroundStyle(Theme.text)
                            Text(skill.description).font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Skill \(skill.name)")
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var agent = editing {
            agent.name = trimmed; agent.color = color; agent.instructions = instructions; agent.model = model
            agent.skills = skillNames.sorted()
            store.update(agent)
        } else {
            var made = store.add(name: trimmed, color: color, instructions: instructions, model: model)
            made.skills = skillNames.sorted()
            store.update(made)
        }
        ui.showNewAgent = false
    }
}
