import Foundation

/// Turns text into vectors with the Embeddings role's model, on Ollama,
/// on this Mac. Without the model, says so and offers to pull it.
@MainActor
final class BrainEmbedder: ObservableObject {
    static let shared = BrainEmbedder()
    static let defaultModel = "nomic-embed-text"

    enum Status: Equatable {
        case unknown
        case ready(String)
        /// Ollama runs, the model isn't there.
        case missing(String)
        case ollamaDown
    }

    @Published private(set) var status: Status = .unknown

    /// The model: the one chosen for the role when it is an Ollama model,
    /// else nomic-embed-text.
    var model: String {
        if let chosen = ModelRouter.shared.configured(.embeddings), chosen.provider == AIProvider.ollama.rawValue, !chosen.model.isEmpty {
            return chosen.model
        }
        return Self.defaultModel
    }

    var ready: Bool { if case .ready = status { return true } else { return false } }

    /// Asks Ollama what it has.
    @discardableResult
    func refresh() async -> Status {
        await OllamaCatalog.shared.refresh()
        let catalog = OllamaCatalog.shared
        let wanted = model
        if !catalog.reachable { status = .ollamaDown }
        else if catalog.installed.contains(where: { $0.name == wanted || $0.name == wanted + ":latest" }) { status = .ready(wanted) }
        else { status = .missing(wanted) }
        return status
    }

    /// The model pulled, with the catalog's progress; then the status again.
    func pull() {
        OllamaCatalog.shared.startPull(model)
    }

    /// nomic wants to know which side a text is on.
    private func prefixed(_ text: String, query: Bool) -> String {
        model.contains("nomic") ? (query ? "search_query: " : "search_document: ") + text : text
    }

    /// One vector per text, or nil when Ollama or the model isn't there.
    func embed(_ texts: [String], query: Bool) async -> [[F32]]? {
        guard !texts.isEmpty else { return [] }
        let body: [String: Any] = ["model": model, "input": texts.map { prefixed($0, query: query) }, "truncate": true]
        guard let out = await AIClient.shared.ollama("api/embed", method: "POST", body: body, timeout: query ? 15 : 180),
              let raw = out["embeddings"] as? [[Double]], raw.count == texts.count
        else {
            if status != .ollamaDown { await refresh() }
            return nil
        }
        if !ready { status = .ready(model) }
        return raw.map { vec -> [F32] in
            // Unit length: a dot product is then the cosine.
            var sum = 0.0
            for x in vec { sum += x * x }
            let norm = sum.squareRoot()
            let scale = norm > 0 ? 1 / norm : 1
            return vec.map { (x: Double) -> F32 in F32(x * scale) }
        }
    }

    /// A line for the person: what is missing and what to do.
    var note: String? {
        switch status {
        case .unknown, .ready: return nil
        case .missing(let name): return "Search by meaning needs the model \(name). Download it, about 270 MB, and it stays on this Mac."
        case .ollamaDown: return "Ollama isn't running, so only exact words are found. Start Ollama for search by meaning."
        }
    }
}
