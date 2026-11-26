import Foundation

/// The chat of one thread, answered by Search's own AIClient: streamed, one
/// request at a time per thread, stopped when asked. No tools yet (Phase 3).
@MainActor
final class ChatRuntime: ObservableObject {
    static let shared = ChatRuntime()

    /// Threads with an answer on its way, for the avatars' blinking eyes.
    @Published private(set) var thinking: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isThinking(agent: UUID) -> Bool {
        AgentStore.shared.threads.contains { $0.agentID == agent && thinking.contains($0.id) }
    }

    static func systemPrompt(for agent: Agent) -> String {
        var text = "You are \(agent.name), an assistant inside Xool OS, a web browser on the user's Mac. Answer in the language the user writes in. Be brief and concrete."
        let own = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { text += "\n\n" + own }
        return text
    }

    func send(_ text: String, in threadID: UUID) {
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
        let system = Self.systemPrompt(for: agent)
        thinking.insert(threadID)
        tasks[threadID] = Task { @MainActor [weak self] in
            // A small local model says whether this needs tools and whether
            // the cloud is worth it; any trouble is the standard route.
            let decision = await DecisionModel.decide(text, recent: history.dropLast().map(\.text))
            guard !Task.isCancelled else { return }
            guard let route = ModelRouter.shared.route(decision, agent: agent) else {
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
        tasks[threadID]?.cancel()
        finish(threadID, error: nil, provider: nil)
    }

    private func finish(_ id: UUID, error: Error?, provider: AIProvider?, quiet: Bool = false) {
        tasks[id] = nil
        thinking.remove(id)
        if quiet {}
        else if let error { fail(id, Self.explain(error, provider: provider)) }
        else {
            // An empty answer with no error is a model that said nothing.
            AgentStore.shared.mutate(id) {
                if let last = $0.messages.indices.last, $0.messages[last].role == .assistant,
                   $0.messages[last].text.isEmpty, $0.messages[last].failed == nil {
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
