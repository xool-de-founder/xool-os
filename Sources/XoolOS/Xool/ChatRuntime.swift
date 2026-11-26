import Foundation

/// The chat of one thread, answered by Search's own AIClient: streamed, one
/// request at a time per thread, stopped when asked. When the DecisionModel
/// says the request needs tools (or can't say), an agent that has a model
/// that takes them runs the tool loop instead (AgentRuntime).
@MainActor
final class ChatRuntime: ObservableObject {
    static let shared = ChatRuntime()

    /// Threads with an answer on its way, for the avatars' blinking eyes.
    @Published private(set) var thinking: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// What each running thread is doing, for the pills.
    @Published private(set) var activity: [UUID: AgentActivity] = [:]
    /// More for a thread's system prompt while an answer is on its way: how to
    /// answer someone who is listening, and the voice's background notes.
    var extra: [UUID: String] = [:]
    /// A site an agent asks to work on, by thread: the thread shows the question.
    @Published var asking: [UUID: SitePermission] = [:]

    func setActivity(_ thread: UUID, _ state: AgentActivity) {
        if state == .idle { activity[thread] = nil } else if activity[thread] != state { activity[thread] = state }
    }

    /// The busiest thing any thread of the agent is doing: waiting for the
    /// user, then working in tabs, then thinking.
    func state(agent: UUID) -> AgentActivity {
        let mine = AgentStore.shared.threads.filter { $0.agentID == agent }.map(\.id)
        let states = mine.compactMap { activity[$0] ?? (thinking.contains($0) ? .thinking : nil) }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.listening) { return .listening }
        let tabs = states.reduce(0) { if case .browsing(let n) = $1 { return $0 + n } else { return $0 } }
        if states.contains(where: { if case .browsing = $0 { return true } else { return false } }) { return .browsing(tabs) }
        return states.isEmpty ? .idle : .thinking
    }

    func isThinking(agent: UUID) -> Bool {
        AgentStore.shared.threads.contains { $0.agentID == agent && thinking.contains($0.id) }
    }

    static func systemPrompt(for agent: Agent) -> String {
        var text = "You are \(agent.name), an assistant inside Xool OS, a web browser on the user's Mac. Answer in the language the user writes in. Be brief and concrete."
        // Jarvis hears and speaks. Without this he says he can't, when dictated text arrives.
        text += "\n\n" + VoiceBridge.shared.abilities
        let own = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { text += "\n\n" + own }
        return text
    }

    /// `decision` is the instant judgement of a spoken sentence (no model asked); `spoken`: the
    /// answer will be read aloud, so a quick voice model may answer a plain question.
    func send(_ text: String, in threadID: UUID, decision given: Decision? = nil, spoken: Bool = false) {
        let store = AgentStore.shared
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking.contains(threadID), let thread = store.thread(threadID),
              let agent = store.agent(thread.agentID) else { return }
        store.mutate(threadID) {
            $0.messages.append(ChatMessage(role: .user, text: text))
            $0.messages.append(ChatMessage(role: .assistant, text: ""))
        }
        let history = (store.thread(threadID)?.messages ?? [])
            .dropLast()
            .filter { !$0.text.isEmpty }
            .map { AIMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        let system = Self.systemPrompt(for: agent) + (extra[threadID].map { "\n\n" + $0 } ?? "")
        // "/name rest": a skill of this agent's, called by hand.
        let skills = SkillStore.shared.skills(for: agent)
        let invoked = SkillStore.invocation(in: text, among: skills)?.skill
        thinking.insert(threadID)
        tasks[threadID] = Task { @MainActor [weak self] in
            // A small local model says whether this needs tools and whether
            // the cloud is worth it; any trouble is the standard route.
            let decision: Decision
            if let given { decision = given } else { decision = await DecisionModel.decide(text, recent: history.dropLast().map(\.text)) }
            guard !Task.isCancelled else { return }
            // Tools unless the small model said it is just a question. A skill
            // called by hand, or a decision that couldn't be made, gets them.
            let withTools = invoked != nil || !decision.decided || decision.needsTools || text.contains("xool-brain://")
            let asked = withTools ? Decision(needsTools: true, preferCloud: decision.preferCloud, decided: decision.decided) : decision
            guard let route = ModelRouter.shared.route(asked, agent: agent, spoken: spoken) else {
                self?.fail(threadID, "No model is chosen. Pick one in the bar below, or start Ollama.")
                self?.finish(threadID, error: nil, provider: nil, quiet: true)
                return
            }
            let attempts = [route.primary] + (route.fallback.map { [$0] } ?? [])
            var lastProvider: AIProvider?
            for (index, choice) in attempts.enumerated() {
                guard let provider = choice.aiProvider else { continue }
                lastProvider = provider
                let key = provider.isLocal ? nil : AIKeys.key(for: provider)
                if !provider.isLocal && key == nil {
                    self?.fail(threadID, "No key for \(provider.name). Add it in Settings › Models.")
                    self?.finish(threadID, error: nil, provider: nil, quiet: true)
                    return
                }
                AgentStore.shared.mutate(threadID) { $0.messages[$0.messages.count - 1].model = choice.label }
                if withTools, provider.takesTools {
                    do {
                        try await AgentRuntime.shared.run(threadID: threadID, agent: agent, choice: choice, provider: provider,
                                                          key: key, history: history, invoked: invoked)
                        self?.finish(threadID, error: nil, provider: provider)
                        return
                    } catch {
                        let last = AgentStore.shared.thread(threadID)?.messages.last
                        let said = !(last?.text.isEmpty ?? true) || !(last?.steps?.isEmpty ?? true)
                        if case AIError.unreachable = error, !said, index < attempts.count - 1 { continue }
                        self?.finish(threadID, error: error, provider: provider)
                        return
                    }
                }
                let stream: AsyncThrowingStream<String, Error> = provider == .thisMac
                    ? AIEngine.shared.stream(system: system, messages: history)
                    : AIClient.shared.stream(provider, model: choice.model, system: system, messages: history, key: key)
                AgentStore.shared.mutate(threadID) { $0.messages[$0.messages.count - 1].model = choice.label }
                do {
                    for try await piece in stream {
                        AgentStore.shared.mutate(threadID) { $0.messages[$0.messages.count - 1].text += piece }
                        if (AgentStore.shared.thread(threadID)?.messages.last?.text.count ?? 0) > 32_000 { break }
                    }
                    self?.finish(threadID, error: nil, provider: provider)
                    return
                } catch {
                    // A local app that isn't there, and nothing said yet: the
                    // cloud, when allowed and a key is kept.
                    let said = !(AgentStore.shared.thread(threadID)?.messages.last?.text.isEmpty ?? true)
                    if case AIError.unreachable = error, !said, index < attempts.count - 1 { continue }
                    self?.finish(threadID, error: error, provider: provider)
                    return
                }
            }
            self?.finish(threadID, error: nil, provider: lastProvider)
        }
    }

    func stop(_ threadID: UUID) {
        let running = thinking.contains(threadID)
        tasks[threadID]?.cancel()
        AgentRuntime.shared.cancel(threadID)
        finish(threadID, error: nil, provider: nil, quiet: true)
        guard running else { AgentStore.shared.saveNow(); return }
        AgentStore.shared.mutate(threadID) {
            if let last = $0.messages.indices.last, $0.messages[last].role == .assistant, $0.messages[last].failed == nil {
                $0.messages[last].failed = "Stopped."
            }
        }
        AgentStore.shared.saveNow()
    }

    private func finish(_ id: UUID, error: Error?, provider: AIProvider?, quiet: Bool = false) {
        tasks[id] = nil
        thinking.remove(id)
        activity[id] = nil
        asking[id] = nil
        extra[id] = nil
        if quiet {}
        else if let error { fail(id, Self.explain(error, provider: provider)) }
        else {
            // An empty answer with no error is a model that said nothing.
            AgentStore.shared.mutate(id) {
                if let last = $0.messages.indices.last, $0.messages[last].role == .assistant,
                   $0.messages[last].text.isEmpty, $0.messages[last].failed == nil, $0.messages[last].steps?.isEmpty != false {
                    $0.messages[last].failed = "The model sent no answer. Try again, or pick another model."
                }
            }
        }
        AgentStore.shared.saveNow()
    }

    private func fail(_ id: UUID, _ why: String) {
        thinking.remove(id)
        AgentStore.shared.mutate(id) {
            guard !$0.messages.isEmpty else { return }
            if $0.messages[$0.messages.count - 1].role == .assistant { $0.messages[$0.messages.count - 1].failed = why }
            else { $0.messages.append(ChatMessage(role: .assistant, text: "", failed: why)) }
        }
    }

    /// What happened and what to do, in plain words.
    static func explain(_ error: Error, provider: AIProvider?) -> String {
        if case AIError.unreachable = error, let provider, provider.isLocal {
            return "\(provider.name) isn't running. Start \(provider.name), then send again."
        }
        if case AIError.http(let status, _) = error, status == 401 || status == 403, let provider {
            return "\(provider.name) refused the key. Check it in Settings › Models."
        }
        return error.localizedDescription
    }
}
