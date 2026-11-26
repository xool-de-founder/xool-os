import Foundation

/// What the small model made of one input.
struct Decision: Equatable {
    /// Needs the agent's tools (browse, search, files), not just an answer.
    var needsTools = false
    /// Too hard for a local model: worth the cloud, if that is allowed.
    var preferCloud = false
    /// False when the model wasn't asked or didn't answer: the defaults.
    var decided = false

    static let standard = Decision()
}

/// A small local model, asked one quick question per input. Anything that
/// goes wrong — no model, Ollama off, too slow, an answer that isn't JSON —
/// is the standard route, silently: a decision is a help, never a gate.
@MainActor
enum DecisionModel {
    static let timeout: UInt64 = 4_000_000_000

    static let system = """
    You route requests for an assistant inside a web browser. Reply with one line of JSON and nothing else:
    {"tools": true|false, "cloud": true|false}
    "tools" is true when the request needs the browser, the web, files, or any action; false for a plain question or chat.
    "cloud" is true only when the request is long, hard, or needs deep reasoning or code; false for everyday requests.
    """

    /// The model that decides: the Decision role, else the smallest model
    /// Ollama has. Always on this Mac.
    static func model() -> ModelChoice? {
        if let set = ModelRouter.shared.configured(.decision) { return set.isLocal ? set : nil }
        return OllamaCatalog.shared.smallest.map { ModelChoice(provider: AIProvider.ollama.rawValue, model: $0.name) }
    }

    /// Worth asking only when the answer can change the route.
    static var useful: Bool {
        let router = ModelRouter.shared
        return router.allowCloud || (router.configured(.agent) != nil && router.configured(.agent) != router.configured(.chat))
    }

    static func decide(_ text: String, recent: [String] = []) async -> Decision {
        guard useful, let choice = model(), let provider = choice.aiProvider, provider != .thisMac else { return .standard }
        var ask = recent.suffix(2).map { "Earlier: " + String($0.prefix(200)) }.joined(separator: "\n")
        if !ask.isEmpty { ask += "\n" }
        ask += "Request: " + String(text.prefix(1200))
        let stream = AIClient.shared.stream(provider, model: choice.model, system: system,
                                            messages: [AIMessage(role: .user, text: ask)], key: nil)
        let reading = Task { () -> String in
            var said = ""
            do { for try await piece in stream { said += piece; if said.count > 400 { break } } } catch { return "" }
            return said
        }
        let timer = Task { try? await Task.sleep(nanoseconds: timeout); reading.cancel() }
        let said = await reading.value
        timer.cancel()
        let result = parse(said) ?? .standard
        if Store.testing { FileHandle.standardError.write(Data("decision: tools=\(result.needsTools) cloud=\(result.preferCloud) decided=\(result.decided) via=\(choice.model)\n".utf8)) }
        return result
    }

    /// The first {...} in the answer; thinking models wrap it in words.
    static func parse(_ raw: String) -> Decision? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let json = try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8)) as? [String: Any],
              json["tools"] is Bool || json["cloud"] is Bool
        else { return nil }
        return Decision(needsTools: json["tools"] as? Bool ?? false, preferCloud: json["cloud"] as? Bool ?? false, decided: true)
    }
}
