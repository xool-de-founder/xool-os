import SwiftUI

/// The panel from the right, inside the page's card (docs/PLAN.md 8, C, E):
/// Jarvis' office in a container of its own on top (the mark, his name, his
/// last line, a row to talk to him), under it his three assistants side by
/// side, under them the other agents with their last line. No profile row.
/// Esc or the button closes it.
struct AgentsOverview: View {
    static let width: CGFloat = 300
    @ObservedObject var ui: XoolUI
    @ObservedObject var store: AgentStore
    @ObservedObject var models: ModelStore
    @ObservedObject var runtime: ChatRuntime
    @ObservedObject var flight: PanelFlight
    @XState private var escape: Any?
    @XState private var message = ""
    @FocusState private var typing: Bool

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

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    office
                    assistantsRow
                    if !store.further.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("More agents").font(Theme.font(Theme.Size.caption, Theme.Weight.label))
                                .foregroundStyle(Theme.textMuted.opacity(0.7))
                                .padding(.horizontal, Theme.Space.s).padding(.bottom, 2)
                            ForEach(store.further) { agent in row(agent) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The panel has no hairline and no ground of its own: it is the card's.
        // Esc closes it, wherever the keys are (the event goes on to
        // whoever else wants it).
        .onAppear {
            escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { MainActor.assumeIsolated { ui.showAgents = false } }
                return event
            }
        }
        .onDisappear { if let escape { NSEvent.removeMonitor(escape) }; escape = nil }
    }

    // MARK: Jarvis' office

    private var office: some View {
        let jarvis = store.jarvis
        let last = store.lastThread(of: jarvis.id)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            XoolButton(radius: Theme.Radius.row, action: { ui.openAgent(jarvis.id) }) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    AgentAvatar(color: jarvis.color, size: 64, thinking: runtime.isThinking(agent: jarvis.id))
                        .reportsFrame("slot.\(jarvis.id)")
                        .opacity(flight.slotsHidden ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(jarvis.name).font(Theme.heading).foregroundStyle(Theme.text)
                            VoiceStatusLine()
                        }
                        Text(last?.lastLine ?? "Your chief agent. Ask, or let him hand it on.")
                            .font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("\(jarvis.name), chief agent. \(last?.lastLine ?? "No messages yet")")
            VoiceSetupCard()
            // Talk to him: the waveform opens a conversation (microphone open, he answers aloud);
            // or type and press Return.
            HStack(spacing: Theme.Space.xs) {
                ConversationButton(size: 28)
                TextField("Talk to \(jarvis.name)", text: $message)
                    .textFieldStyle(.plain).font(Theme.body).focused($typing)
                    .onSubmit(sendToJarvis)
                    .accessibilityLabel("Message to \(jarvis.name)")
                if !message.isEmpty {
                    XoolIconButton(symbol: "arrow.up", label: "Send to \(jarvis.name)") { sendToJarvis() }
                }
            }
            .padding(.horizontal, Theme.Space.xs).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(typing ? Theme.focus : Theme.line, lineWidth: typing ? 2 : 1))
        }
        .padding(Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .contextMenu {
            Button("Edit Jarvis…") { ui.editing = jarvis; ui.showNewAgent = true }
        }
    }

    private func sendToJarvis() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        let id = store.jarvis.id
        ui.openAgent(id)
        if let thread = ui.front { ChatRuntime.shared.send(text, in: thread) }
    }

    // MARK: the three

    private var assistantsRow: some View {
        let mine = store.assistants
        return HStack(alignment: .top, spacing: Theme.Space.xs) {
            ForEach(0..<3, id: \.self) { index in
                if index < mine.count {
                    tile(mine[index])
                } else {
                    emptyTile
                }
            }
        }
    }

    private func tile(_ agent: Agent) -> some View {
        Button { ui.openAgent(agent.id) } label: {
            VStack(spacing: 6) {
                AgentAvatar(color: agent.color, size: 44, thinking: runtime.isThinking(agent: agent.id))
                    .reportsFrame("slot.\(agent.id)")
                    .opacity(flight.slotsHidden ? 0 : 1)
                Text(agent.name).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(.vertical, Theme.Space.s).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                .fill(activeAgent == agent.id ? Theme.raised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xoolFocus(radius: Theme.Radius.popover) { ui.openAgent(agent.id) }
        .accessibilityLabel("\(agent.name), assistant")
        .contextMenu {
            Button("Edit agent…") { ui.editing = agent; ui.showNewAgent = true }
            Button("Remove from assistants") { store.setAssistant(agent.id, false) }
        }
    }

    private var emptyTile: some View {
        Button { ui.editing = nil; ui.showNewAgent = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textMuted)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 44 * 0.42, style: .continuous)
                        .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text("Assistant").font(Theme.small).foregroundStyle(Theme.textMuted)
            }
            .padding(.vertical, Theme.Space.s).frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xoolFocus(radius: Theme.Radius.popover) { ui.editing = nil; ui.showNewAgent = true }
        .accessibilityLabel("Add an assistant")
    }

    // MARK: the rest

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
            Button("Make assistant of Jarvis") { store.setAssistant(agent.id, true) }
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
            if editing?.isMain != true {
            HStack(spacing: Theme.Space.s) {
                ForEach(AgentColor.choosable) { option in
                    XoolButton(radius: 8, action: { color = option }) {
                        Circle().fill(option.solid).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: color == option ? 2 : 0).padding(-3))
                            .frame(width: Theme.target, height: Theme.target)
                    }
                    .accessibilityLabel("\(option.name)\(color == option ? ", selected" : "")")
                }
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
