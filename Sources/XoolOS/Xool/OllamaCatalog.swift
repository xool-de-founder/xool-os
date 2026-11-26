import Foundation

/// How a local model sits in this Mac's memory: the traffic light of
/// jarvis-on-nod. Shown with a symbol and words, never colour alone.
enum RAMFit: Equatable {
    case fits, tight, tooBig

    var symbol: String {
        switch self {
        case .fits: return "checkmark.circle"
        case .tight: return "exclamationmark.triangle"
        case .tooBig: return "xmark.octagon"
        }
    }

    var words: String {
        switch self {
        case .fits: return "fits in memory"
        case .tight: return "tight on memory"
        case .tooBig: return "too big for this Mac"
        }
    }

    /// A model of `size` bytes on disk wants about that much memory, and a
    /// little more for the conversation.
    static func of(size: Int64, ram: UInt64 = ProcessInfo.processInfo.physicalMemory) -> RAMFit {
        guard size > 0, ram > 0 else { return .fits }
        let share = Double(size) * 1.1 / Double(ram)
        return share <= 0.6 ? .fits : share <= 0.85 ? .tight : .tooBig
    }
}

struct OllamaModel: Identifiable, Equatable {
    var name: String
    var size: Int64
    /// Loaded in memory right now (/api/ps).
    var running = false
    var id: String { name }
    var fit: RAMFit { RAMFit.of(size: size) }
    var sizeText: String { size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "" }
}

/// What Ollama has: installed models (/api/tags), loaded ones (/api/ps), and
/// a pull with its progress. Asked only when Settings or the picker is open.
@MainActor
final class OllamaCatalog: ObservableObject {
    static let shared = OllamaCatalog()

    struct Pull: Equatable {
        var name: String
        var status = "Starting…"
        var completed: Int64 = 0
        var total: Int64 = 0
        var failed: String?
        var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    }

    @Published private(set) var installed: [OllamaModel] = []
    /// Whether Ollama answered the last time it was asked.
    @Published private(set) var reachable = false
    @Published private(set) var asked = false
    @Published private(set) var pull: Pull?
    private var pulling: Task<Void, Never>?

    /// jarvis-on-nod's choice by memory: 48 GB and up the large one.
    static func recommended(ram: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        ram >= 48 * 1_073_741_824 ? "qwen3.6:35b" : "gpt-oss:20b"
    }

    var recommendedName: String { Self.recommended() }
    var hasRecommended: Bool { installed.contains { $0.name == recommendedName || $0.name == recommendedName + ":latest" } }

    /// Reads /api/tags and /api/ps. Ollama's cloud-run models are left out,
    /// as in AIClient.localModels: nothing chosen here leaves this Mac.
    func refresh() async {
        let tags = await AIClient.shared.ollama("api/tags")
        asked = true
        guard let tags else {
            reachable = false
            installed = []
            return
        }
        reachable = true
        let loaded = Set((await AIClient.shared.ollama("api/ps")?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        installed = Self.parse(tags).map { model in
            var model = model
            model.running = loaded.contains(model.name)
            return model
        }
    }

    static func parse(_ tags: [String: Any]) -> [OllamaModel] {
        (tags["models"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, entry["remote_host"] == nil, entry["remote_model"] == nil,
                  !name.hasSuffix("-cloud"), !name.contains(":cloud"), !name.contains("-cloud:")
            else { return nil }
            return OllamaModel(name: name, size: (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
        .sorted { $0.name < $1.name }
    }

    /// The models a voice does best with, quick ones first (from jarvis-on-nod's MODEL_PREFERENCE).
    static let voicePreference = ["qwen3.6:35b-a3b", "qwen3-30b", "qwen3:30b", "gemma4:12b", "qwen3.6:35b", "qwen3.5:35b", "gpt-oss:20b",
                                  "gemma4", "qwen3.6", "qwen3.5:27b", "qwen3.5", "qwen3"]

    /// The quickest good model installed for a spoken answer, if any is on the list.
    func quickVoice() -> ModelChoice? {
        let names = installed.map(\.name)
        for wanted in Self.voicePreference {
            if let hit = names.first(where: { $0 == wanted || $0.hasPrefix(wanted) }) {
                return ModelChoice(provider: AIProvider.ollama.rawValue, model: hit)
            }
        }
        return nil
    }

    /// The smallest installed model under 6 GB, for the quick decisions,
    /// when none is chosen: embedding models don't chat and are skipped.
    var smallest: OllamaModel? {
        installed.filter { $0.size > 0 && $0.size < 6 * 1_073_741_824 && !$0.name.contains("embed") }
            .min { $0.size < $1.size }
    }

    func startPull(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, pulling == nil else { return }
        pull = Pull(name: name)
        pulling = Task { @MainActor [weak self] in
            do {
                for try await event in AIClient.shared.ollamaStream("api/pull", body: ["model": name, "stream": true]) {
                    guard var current = self?.pull else { return }
                    current.status = (event["status"] as? String) ?? current.status
                    if let total = (event["total"] as? NSNumber)?.int64Value, total > 0 {
                        current.total = total
                        current.completed = (event["completed"] as? NSNumber)?.int64Value ?? current.completed
                    }
                    self?.pull = current
                }
                self?.pull = nil
            } catch {
                let why: String
                if case AIError.unreachable = error { why = "Ollama isn't running. Start Ollama, then pull again." }
                else { why = error.localizedDescription }
                self?.pull?.failed = why
            }
            self?.pulling = nil
            await self?.refresh()
            await ModelStore.shared.refresh()
        }
    }

    func cancelPull() {
        pulling?.cancel()
        pulling = nil
        pull = nil
    }

    func dismissFailure() { if pull?.failed != nil { pull = nil } }
}
