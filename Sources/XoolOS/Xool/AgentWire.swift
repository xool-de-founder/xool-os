import Foundation

// Tool calls on the wire. Ollama, LM Studio, OpenAI and OpenRouter speak
// OpenAI's chat completions (`tools`, `tool_calls`, role "tool"); Anthropic
// speaks `tool_use` and `tool_result` blocks. Gemini and the model on this Mac
// aren't asked for tools: the thread answers as a plain chat there.
//
// Same rules as AIClient's own requests (it is the same session): the key goes
// in a header to the provider's own host and nowhere else, no redirect is
// followed, and nothing of a request is logged.

/// A tool the model may call. `parameters` is a JSON schema.
struct ToolSpec {
    let name: String
    let detail: String
    let parameters: [String: Any]
}

struct ToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// What has been said in one run, in the order it happened.
enum AgentTurn {
    case user(String)
    case assistant(String, [ToolCall])
    case result(ToolCall, String)
}

enum AgentEvent {
    case text(String)
    case call(ToolCall)
}

extension AIProvider {
    /// Providers asked for tools. Gemini and the engine on this Mac answer as chat.
    var takesTools: Bool { self != .thisMac && self != .gemini }
}

extension AIClient {
    func agentStream(_ provider: AIProvider, model: String, system: String, turns: [AgentTurn],
                     tools: [ToolSpec], key: String?) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.agentRequest(provider, model: model, system: system, turns: turns, tools: tools, key: key)
                    let (bytes, response) = try await session.bytes(for: request, delegate: self)
                    guard let http = response as? HTTPURLResponse else { throw AIError.unreadable }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 4096 { break }
                        }
                        throw AIError.http(http.statusCode, Self.said(body, hiding: key))
                    }
                    var collector = CallCollector()
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if data == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { continue }
                        if let failure = Self.failure(json, event: event, hiding: key) { throw failure }
                        collector.take(provider.wire, json)
                        if let piece = Self.piece(provider.wire, json), !piece.isEmpty { continuation.yield(.text(piece)) }
                    }
                    for call in collector.calls() { continuation.yield(.call(call)) }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: AIError.unreachable(Self.reason(error, provider)))
                } catch {
                    continuation.finish(throwing: AIError.unreadable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func agentRequest(_ provider: AIProvider, model: String, system: String, turns: [AgentTurn],
                             tools: [ToolSpec], key: String?) throws -> URLRequest {
        let url: URL
        var body: [String: Any]
        switch provider.wire {
        case .openAI:
            url = provider.base.appendingPathComponent("chat/completions")
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            for turn in turns {
                switch turn {
                case .user(let text):
                    messages.append(["role": "user", "content": text])
                case .assistant(let text, let calls):
                    var message: [String: Any] = ["role": "assistant", "content": text]
                    if !calls.isEmpty {
                        message["tool_calls"] = calls.map { call -> [String: Any] in
                            ["id": call.id, "type": "function",
                             "function": ["name": call.name, "arguments": json(call.arguments)]]
                        }
                    }
                    messages.append(message)
                case .result(let call, let text):
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": text])
                }
            }
            body = ["model": model, "stream": true, "messages": messages]
            if !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.detail, "parameters": $0.parameters]] }
            }
            if provider == .openRouter { body["provider"] = ["zdr": true] }
            body[provider == .openAI ? "max_completion_tokens" : "max_tokens"] = 4096
            if provider == .ollama || provider == .lmStudio { body["reasoning_effort"] = "none" }
        case .anthropic:
            url = provider.base.appendingPathComponent("messages")
            var messages: [[String: Any]] = []
            var pending: [[String: Any]] = []
            func flush() {
                if !pending.isEmpty { messages.append(["role": "user", "content": pending]); pending = [] }
            }
            for turn in turns {
                switch turn {
                case .user(let text):
                    flush()
                    messages.append(["role": "user", "content": text])
                case .assistant(let text, let calls):
                    flush()
                    var blocks: [[String: Any]] = []
                    if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                    for call in calls { blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.arguments]) }
                    messages.append(["role": "assistant", "content": blocks])
                case .result(let call, let text):
                    pending.append(["type": "tool_result", "tool_use_id": call.id, "content": text])
                }
            }
            flush()
            body = ["model": model, "stream": true, "max_tokens": 4096, "system": system, "messages": messages]
            if !tools.isEmpty {
                body["tools"] = tools.map { ["name": $0.name, "description": $0.detail, "input_schema": $0.parameters] }
            }
        case .gemini:
            throw AIError.refusedHost
        }
        guard allowed(url, for: provider) else { throw AIError.refusedHost }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !provider.isLocal {
            guard let key, !key.isEmpty else { throw AIError.noKey }
            if provider.wire == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Tool calls arrive in pieces — a name here, a bit of the arguments there —
/// and are handed on whole once the stream has ended.
struct CallCollector {
    private struct Partial { var id = ""; var name = ""; var arguments = "" }
    private var parts: [Int: Partial] = [:]

    mutating func take(_ wire: AIProvider.Wire, _ json: [String: Any]) {
        switch wire {
        case .openAI:
            let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any]
            for piece in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                let index = piece["index"] as? Int ?? parts.count
                var part = parts[index] ?? Partial()
                if let id = piece["id"] as? String, !id.isEmpty { part.id = id }
                let function = piece["function"] as? [String: Any]
                if let name = function?["name"] as? String { part.name += name }
                if let arguments = function?["arguments"] as? String { part.arguments += arguments }
                else if let object = function?["arguments"] as? [String: Any] { part.arguments = AIClient.json(object) }
                parts[index] = part
            }
        case .anthropic:
            let index = json["index"] as? Int ?? 0
            switch json["type"] as? String {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    parts[index] = Partial(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: "")
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
                   var part = parts[index] {
                    part.arguments += delta["partial_json"] as? String ?? ""
                    parts[index] = part
                }
            default: break
            }
        case .gemini: break
        }
    }

    func calls() -> [ToolCall] {
        parts.keys.sorted().compactMap { index in
            guard let part = parts[index], !part.name.isEmpty else { return nil }
            let arguments = (try? JSONSerialization.jsonObject(with: Data(part.arguments.utf8))) as? [String: Any] ?? [:]
            return ToolCall(id: part.id.isEmpty ? "call_" + String(UUID().uuidString.prefix(8)) : part.id, name: part.name, arguments: arguments)
        }
    }
}
