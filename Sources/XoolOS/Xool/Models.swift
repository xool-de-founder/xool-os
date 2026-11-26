import Foundation

/// Which model answers, and which are there to pick: the local apps asked
/// when the picker opens, a cloud provider only when a key is kept for it.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    private let providerKey = "xool.model.provider"
    private let modelKey = "xool.model.name"

    @Published var current: ModelChoice? {
        didSet {
            guard let current else { return }
            Store.settings.set(current.provider, forKey: providerKey)
            Store.settings.set(current.model, forKey: modelKey)
        }
    }

    struct Entry: Identifiable, Hashable {
        let choice: ModelChoice
        var id: String { choice.provider + "/" + choice.model }
        var title: String { choice.model.isEmpty ? (choice.aiProvider?.name ?? "") : choice.model }
        var detail: String { choice.aiProvider?.name ?? "" }
    }

    @Published private(set) var local: [Entry] = []
    @Published private(set) var cloud: [Entry] = []
    @Published private(set) var refreshing = false
    /// What is not reachable, by provider name, for a plain explanation.
    @Published private(set) var offline: [String] = []

    init() {
        if let provider = Store.settings.string(forKey: providerKey), AIProvider(rawValue: provider) != nil {
            current = ModelChoice(provider: provider, model: Store.settings.string(forKey: modelKey) ?? "")
        }
    }

    /// Cloud providers with a key kept: their default model is offered, and
    /// the model field in Settings › AI can name another.
    private func cloudEntries() -> [Entry] {
        [AIProvider.anthropic, .openAI, .gemini, .openRouter].compactMap { provider in
            guard AIKeys.hint(for: provider) != nil else { return nil }
            let chosen = ((Store.settings.dictionary(forKey: "ai.models") as? [String: String])?[provider.rawValue] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = chosen.isEmpty ? provider.defaultModel : chosen
            return Entry(choice: ModelChoice(provider: provider.rawValue, model: model))
        }
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        cloud = cloudEntries()
        var found: [Entry] = []
        var down: [String] = []
        for provider in [AIProvider.ollama, .lmStudio] {
            let names = await AIClient.shared.localModels(provider)
            if names.isEmpty { down.append(provider.name) }
            found += names.map { Entry(choice: ModelChoice(provider: provider.rawValue, model: $0)) }
        }
        local = found
        offline = down
        // Nothing chosen yet, or the choice is gone: the first local model.
        if current == nil || (current.map { !all.contains(Entry(choice: $0)) } ?? false), let first = (local + cloud).first {
            if current == nil { current = first.choice }
        }
    }

    var all: [Entry] { local + cloud }

    /// The model an agent uses now: its own, or the bar's.
    func resolve(_ agent: Agent?) -> ModelChoice? { agent?.model ?? current }
}
