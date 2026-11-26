import Foundation
import SwiftUI

/// A model a thread or an agent talks to: a provider and the model's name.
struct ModelChoice: Codable, Equatable, Hashable {
    var provider: String
    var model: String

    var aiProvider: AIProvider? { AIProvider(rawValue: provider) }
    var isLocal: Bool { aiProvider?.isLocal ?? false }
    var label: String { model.isEmpty ? (aiProvider?.name ?? provider) : model }
}

struct Agent: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var color: AgentColor
    var instructions: String
    /// Nil: follows the model chosen in the bar.
    var model: ModelChoice?
    var pinned = true
    /// Names of the skills it keeps (SkillStore). Nil in files written before.
    var skills: [String]?
    var created = Date()
    var lastActive = Date()
    /// Jarvis, the one main agent (docs/PLAN.md 8, C): never deleted, may be renamed.
    var main: Bool?
    /// Jarvis's three assistants; nil takes the first three other agents.
    var assistantIDs: [UUID]?

    var accent: Color { color.solid }
    var isMain: Bool { main == true }

    static let starter: [Agent] = []
}

/// One thing an agent did while answering: "Opens example.com", "Clicks
/// Next". A step in a tab jumps to that tab when clicked.
struct AgentStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case search, open, read, click, type, wait, back, skill, brain, delegate, other }
    enum State: String, Codable { case running, done, failed }
    var id = UUID()
    var kind: Kind
    var text: String
    var state: State = .running
    /// The tab it happened in, and its address for when that tab is gone.
    var tab: UUID?
    var url: String?
    /// Why it failed, or what came of it.
    var note: String?
    /// For a delegation: the thread the other agent works in.
    var thread: UUID?
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var failed: String?
    /// The model that answered, for an assistant message.
    var model: String?
    var date = Date()
    /// What the agent did on the way to this answer.
    var steps: [AgentStep]?
}

struct ChatThread: Identifiable, Codable, Equatable {
    var id = UUID()
    var agentID: UUID
    var messages: [ChatMessage] = []
    var updated = Date()

    var title: String {
        messages.first(where: { $0.role == .user })?.text.prefix(48).description ?? "New thread"
    }
    var lastLine: String {
        messages.last(where: { !$0.text.isEmpty })?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages yet"
    }
}

/// Agents and their threads, as JSON under Application Support/Xool/agents.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var threads: [ChatThread] = []

    private let folder: URL
    private var agentsFile: URL { folder.appendingPathComponent("agents.json") }
    private var threadsFile: URL { folder.appendingPathComponent("threads.json") }
    private var saving: Task<Void, Never>?

    init(folder: URL = Store.folder.appendingPathComponent("agents", isDirectory: true)) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        agents = Self.read([Agent].self, from: agentsFile) ?? []
        threads = Self.read([ChatThread].self, from: threadsFile) ?? []
        ensureJarvis()
    }

    // MARK: Jarvis and his assistants (docs/PLAN.md 8, C)

    static let jarvisInstructions = """
    You are Jarvis, the user's chief agent. You answer directly when you can. For a job that fits one of your \
    assistants or another agent better, hand it over with the delegate tool (agent name, then a complete task: \
    they know nothing of this conversation), then use what they report back in your answer.
    """

    /// There is always exactly one main agent, first in the list.
    private func ensureJarvis() {
        guard !agents.contains(where: \.isMain) else { return }
        var jarvis = Agent(name: "Jarvis", color: .silver, instructions: Self.jarvisInstructions, model: nil)
        jarvis.main = true
        agents.insert(jarvis, at: 0)
        write(agents, to: agentsFile)
    }

    var jarvis: Agent { agents.first(where: \.isMain) ?? agents[0] }

    /// His three: the ones chosen, else the first three other agents.
    var assistants: [Agent] {
        let others = agents.filter { !$0.isMain }
        if let ids = jarvis.assistantIDs {
            return ids.compactMap { id in others.first { $0.id == id } }.prefix(3).map { $0 }
        }
        return Array(others.prefix(3))
    }

    /// Everyone else.
    var further: [Agent] {
        let mine = Set(assistants.map(\.id))
        return agents.filter { !$0.isMain && !mine.contains($0.id) }
    }

    func isAssistant(_ id: UUID) -> Bool { assistants.contains { $0.id == id } }

    /// Make an agent one of the three (the oldest steps out when full), or not.
    func setAssistant(_ id: UUID, _ on: Bool) {
        var ids = assistants.map(\.id)
        ids.removeAll { $0 == id }
        if on { ids.append(id); if ids.count > 3 { ids.removeFirst(ids.count - 3) } }
        var boss = jarvis
        boss.assistantIDs = ids
        update(boss)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Saved a moment after the last change, so a streaming answer isn't
    /// written once per piece.
    private func scheduleSave() {
        saving?.cancel()
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.write(self.agents, to: self.agentsFile)
            self.write(self.threads, to: self.threadsFile)
        }
    }

    func saveNow() {
        saving?.cancel()
        write(agents, to: agentsFile)
        write(threads, to: threadsFile)
    }

    // MARK: agents

    func agent(_ id: UUID) -> Agent? { agents.first { $0.id == id } }

    @discardableResult
    func add(name: String, color: AgentColor, instructions: String, model: ModelChoice?) -> Agent {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = Agent(name: name.isEmpty ? "Agent" : name, color: color, instructions: instructions, model: model)
        agents.append(agent)
        scheduleSave()
        return agent
    }

    func update(_ agent: Agent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index] = agent
        scheduleSave()
    }

    func remove(_ id: UUID) {
        guard agent(id)?.isMain != true else { return }
        agents.removeAll { $0.id == id }
        threads.removeAll { $0.agentID == id }
        scheduleSave()
    }

    func move(_ id: UUID, before other: UUID) {
        guard id != other, let from = agents.firstIndex(where: { $0.id == id }),
              let to = agents.firstIndex(where: { $0.id == other }) else { return }
        let agent = agents.remove(at: from)
        agents.insert(agent, at: agents.firstIndex(where: { $0.id == other }) ?? to)
        scheduleSave()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var agent = agent(id) else { return }
        agent.pinned = pinned
        update(agent)
    }

    /// Colours not used yet come first, so each new agent looks different.
    func nextColor() -> AgentColor {
        let used = Set(agents.map(\.color))
        return AgentColor.choosable.first { !used.contains($0) } ?? AgentColor.choosable[agents.count % AgentColor.choosable.count]
    }

    // MARK: threads

    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }

    func threads(of agent: UUID) -> [ChatThread] {
        threads.filter { $0.agentID == agent }.sorted { $0.updated > $1.updated }
    }

    func lastThread(of agent: UUID) -> ChatThread? { threads(of: agent).first }

    @discardableResult
    func newThread(for agent: UUID) -> ChatThread {
        let thread = ChatThread(agentID: agent)
        threads.append(thread)
        scheduleSave()
        return thread
    }

    func mutate(_ id: UUID, _ change: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[index])
        threads[index].updated = Date()
        if let a = agents.firstIndex(where: { $0.id == threads[index].agentID }) { agents[a].lastActive = Date() }
        scheduleSave()
    }

    func deleteThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Agents by latest activity, for the overview.
    var byActivity: [Agent] { agents.sorted { $0.lastActive > $1.lastActive } }
}
