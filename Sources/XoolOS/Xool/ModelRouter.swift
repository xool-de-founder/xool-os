import Foundation

/// What a model is for. Each role has one provider + model; the others
/// follow Chat until one is chosen.
enum ModelRole: String, CaseIterable, Identifiable {
    case chat, agent, decision, embeddings, voice
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .agent: return "Agent & tools"
        case .decision: return "Decision"
        case .embeddings: return "Embeddings"
        case .voice: return "Voice"
        }
    }

    var detail: String {
        switch self {
        case .chat: return "The default for every conversation"
        case .agent: return "Used when an agent has to act: browse, search, use tools"
        case .decision: return "Small and quick, on this Mac: decides tools or not, local or cloud"
        case .embeddings: return "Turns text into vectors for the second brain. Local"
        case .voice: return "Answers in a spoken conversation. Quick, short"
        }
    }

    /// Roles that only make sense on this Mac.
    var localOnly: Bool { self == .decision || self == .embeddings }
}

/// Which model answers what: role → provider and model, and the way out
/// when a local one doesn't answer (to the cloud, only if allowed and a key
/// is kept).
@MainActor
final class ModelRouter: ObservableObject {
    static let shared = ModelRouter()

    private static let allowKey = "xool.model.allowCloud"
    private static func key(_ role: ModelRole) -> String { "xool.role.\(role.rawValue)" }

    @Published private var chosen: [ModelRole: ModelChoice] = [:]
    /// Off until the user says so: nothing goes to the cloud on its own.
    @Published var allowCloud: Bool {
        didSet { Store.settings.set(allowCloud, forKey: Self.allowKey) }
    }

    init() {
        allowCloud = Store.settings.bool(forKey: Self.allowKey)
        for role in ModelRole.allCases where role != .chat {
            if let provider = Store.settings.string(forKey: Self.key(role) + ".provider"), AIProvider(rawValue: provider) != nil {
                chosen[role] = ModelChoice(provider: provider, model: Store.settings.string(forKey: Self.key(role) + ".model") ?? "")
            }
        }
    }

    /// What was set for the role itself; Chat is the bar's model.
    func configured(_ role: ModelRole) -> ModelChoice? {
        role == .chat ? ModelStore.shared.current : chosen[role]
    }

    func set(_ choice: ModelChoice?, for role: ModelRole) {
        if role == .chat {
            if let choice { ModelStore.shared.current = choice }
            return
        }
        chosen[role] = choice
        if let choice {
            Store.settings.set(choice.provider, forKey: Self.key(role) + ".provider")
            Store.settings.set(choice.model, forKey: Self.key(role) + ".model")
        } else {
            Store.settings.removeObject(forKey: Self.key(role) + ".provider")
            Store.settings.removeObject(forKey: Self.key(role) + ".model")
        }
    }

    /// The model for a role: the agent's own for chat and agent work, then
    /// the role's, then Chat's.
    func choice(for role: ModelRole, agent: Agent? = nil) -> ModelChoice? {
        if let own = agent?.model, role == .chat || role == .agent { return own }
        return configured(role) ?? (role.localOnly ? nil : configured(.chat))
    }

    /// A cloud model can answer only with a key kept for it.
    func usable(_ choice: ModelChoice) -> Bool {
        guard let provider = choice.aiProvider else { return false }
        return provider.isLocal || AIKeys.hint(for: provider) != nil
    }

    /// The way out for a local model: a cloud one the user chose somewhere
    /// (a role, the bar), else the first provider with a key. Nil unless the
    /// cloud is allowed and a key is there.
    func cloudFallback(agent: Agent? = nil) -> ModelChoice? {
        guard allowCloud else { return nil }
        let preferred = [agent?.model, configured(.agent), configured(.chat)].compactMap { $0 }
        if let hit = preferred.first(where: { !$0.isLocal && usable($0) }) { return hit }
        return ModelStore.shared.cloudEntries().first(where: { usable($0.choice) })?.choice
    }

    struct Route: Equatable {
        var primary: ModelChoice
        /// Tried when the primary is a local app that isn't there.
        var fallback: ModelChoice?
        var role: ModelRole
    }

    /// Where one turn goes, given what the DecisionModel said. An agent's
    /// own model is the user's explicit word and is never overruled.
    func route(_ decision: Decision, agent: Agent?) -> Route? {
        let role: ModelRole = decision.needsTools ? .agent : .chat
        guard var primary = choice(for: role, agent: agent) else { return nil }
        if decision.preferCloud, agent?.model == nil, let cloud = cloudFallback(agent: agent) { primary = cloud }
        let fallback = primary.isLocal ? cloudFallback(agent: agent) : nil
        return Route(primary: primary, fallback: fallback, role: role)
    }
}
