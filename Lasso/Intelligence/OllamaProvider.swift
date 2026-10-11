import Foundation

/// Talks to a local Ollama server (default `http://localhost:11434`) for the "bigger model"
/// path — e.g. `qwen3:4b`. Runs on this machine; no data leaves the Mac, but it is a separate
/// process from the app (hence `isAppleOnDevice == false`).
struct OllamaProvider: IntelligenceProvider {
    let model: String
    let baseURL: URL
    /// Context window to request (`options.num_ctx`). Ollama otherwise loads only ~4096 tokens no matter
    /// the model, so this is what actually unlocks a large-context local model. nil = Ollama's default.
    let numCtx: Int?

    var name: String { "Ollama · \(model)" }
    let isAppleOnDevice = false
    let isLocal = true

    init(model: String = "qwen3:4b",
         baseURL: URL = OllamaEndpoint.baseURL,
         numCtx: Int? = nil) {
        self.model = model
        self.baseURL = baseURL
        self.numCtx = numCtx
    }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.

    Answers appear in a narrow floating panel, so write plain sentences — no tables, no headings, and \
    no LaTeX (the panel does not render math). Use a short bullet list only for genuinely parallel \
    items, and a fenced code block with a language tag for any code or command.
    """

    func checkAvailability() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var userContent = prompt
        if let context, !context.isEmpty {
            userContent += "\n\n--- On-screen text ---\n\(context)"
        }
        return stream(messages: [
            .init(role: "system", content: Self.systemPrompt),
            .init(role: "user", content: userContent),
        ])
    }

    /// Native multi-turn chat. Maps each `ChatTurn` to an Ollama message; a turn carrying an image
    /// sets the per-message `images: [base64]` (the model must be multimodal — the caller routes
    /// non-vision models through a text description instead).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        var wire: [ChatRequest.Message] = []
        if !messages.contains(where: { $0.role == .system }) {
            wire.append(.init(role: "system", content: Self.systemPrompt))
        }
        for turn in messages {
            wire.append(.init(role: turn.role.rawValue, content: turn.text,
                              images: turn.imageBase64s.isEmpty ? nil : turn.imageBase64s))
        }
        return stream(messages: wire)
    }

    // MARK: - Tool calling (industry-standard function calling)

    /// Only tool-capable model families — passing `tools` to others makes Ollama error.
    var supportsTools: Bool { OllamaModels.supportsTools(model) }

    /// Wire `messages` as dictionaries (the tool path needs dynamic `tool_calls`, so it bypasses the
    /// Codable `ChatRequest`). Adds the default system turn when none is present.
    private func wireMessages(_ messages: [ChatTurn]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        if !messages.contains(where: { $0.role == .system }) {
            wire.append(["role": "system", "content": Self.systemPrompt])
        }
        for turn in messages {
            var msg: [String: Any] = ["role": turn.role.rawValue, "content": turn.text]
            if !turn.imageBase64s.isEmpty { msg["images"] = turn.imageBase64s }
            wire.append(msg)
        }
        return wire
    }

    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error> {
        // Build the (non-Sendable) wire dictionaries *inside* the Task from the Sendable inputs, so
        // nothing non-Sendable crosses the task boundary.
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var wire = self.wireMessages(messages)
                    let toolsWire: [[String: Any]] = tools.map {
                        ["type": "function",
                         "function": ["name": $0.name, "description": $0.description,
                                      "parameters": $0.jsonSchema]]
                    }
                    for round in 0..<maxToolRounds {
                        let offerTools = round < maxToolRounds - 1
                        let result = try await self.streamChat(
                            messages: wire, tools: offerTools ? toolsWire : [],
                            continuation: continuation)
                        guard !result.calls.isEmpty else { continuation.finish(); return }

                        // Echo the assistant's tool_calls, then return a `tool` message per call.
                        wire.append([
                            "role": "assistant", "content": result.text,
                            "tool_calls": result.calls.map {
                                ["function": ["name": $0.name, "arguments": $0.argumentsObject]]
                            },
                        ])
                        for call in result.calls {
                            let output = await execute(
                                ToolCall(id: call.name, name: call.name, argumentsJSON: call.argumentsJSON))
                            wire.append(["role": "tool", "content": output])
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream one `/api/chat` call: yield content deltas live and collect any `tool_calls` (Ollama
    /// emits these as whole objects, not split across chunks). Returns content + assembled calls.
    private func streamChat(messages: [[String: Any]], tools: [[String: Any]],
                            continuation: AsyncThrowingStream<String, Error>.Continuation)
        async throws -> (text: String, calls: [AssembledToolCall]) {
        var bodyDict: [String: Any] = ["model": model, "stream": true, "messages": messages]
        if !tools.isEmpty { bodyDict["tools"] = tools }
        if let numCtx { bodyDict["options"] = ["num_ctx": numCtx] }
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw IntelligenceError.server("Couldn't encode the request.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server(
                "Ollama returned HTTP \(code). Is `ollama serve` running and is \(model) pulled?")
        }

        var text = ""
        var calls: [AssembledToolCall] = []
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = json["error"] as? String { throw IntelligenceError.server(err) }
            if let message = json["message"] as? [String: Any] {
                if let content = message["content"] as? String, !content.isEmpty {
                    text += content; continuation.yield(content)
                }
                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        guard let fn = tc["function"] as? [String: Any],
                              let name = fn["name"] as? String else { continue }
                        let argsObject = fn["arguments"] as? [String: Any] ?? [:]
                        let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObject))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        calls.append(AssembledToolCall(name: name, argumentsJSON: argsJSON,
                                                       argumentsObject: argsObject))
                    }
                }
            }
            if json["done"] as? Bool == true { break }
        }
        return (text, calls)
    }

    struct AssembledToolCall {
        var name = ""
        var argumentsJSON = "{}"
        var argumentsObject: [String: Any] = [:]
    }

    // MARK: - Structured output (native JSON-schema mode)

    /// Ollama's `format` field accepts a JSON Schema and constrains decoding to it, so this is a real
    /// guarantee about the shape rather than a request the model may ignore. Non-streaming, tool-free,
    /// and with no system prompt: harness prompts are self-contained, and the chat persona would only
    /// add tokens and tempt the model into prose.
    func respondJSON(prompt: String, schemaName: String, schemaJSON: String,
                     maxTokens: Int) async throws -> String? {
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        else { return nil }

        var options: [String: Any] = ["temperature": 0, "num_predict": maxTokens]
        if let numCtx { options["num_ctx"] = numCtx }
        let bodyDict: [String: Any] = [
            "model": model,
            "stream": false,
            "format": schema,
            "options": options,
            "messages": [["role": "user", "content": prompt]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return content
    }

    private func stream(messages: [ChatRequest.Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeChatRequest(messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw IntelligenceError.server(
                            "Ollama returned HTTP \(code). Is `ollama serve` running and is \(model) pulled?")
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try decoder.decode(ChatChunk.self, from: data)
                        if let err = chunk.error {
                            throw IntelligenceError.server(err)
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeChatRequest(messages: [ChatRequest.Message]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(model: model, stream: true, messages: messages,
                               options: numCtx.map { ChatRequest.Options(num_ctx: $0) })
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - Wire types

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
        var images: [String]? = nil   // base64 JPEGs, for multimodal models
    }
    struct Options: Encodable { let num_ctx: Int }
    let model: String
    let stream: Bool
    let messages: [Message]
    var options: Options? = nil
}

private struct ChatChunk: Decodable {
    struct Message: Decodable { let role: String?; let content: String? }
    let message: Message?
    let done: Bool
    let error: String?
}
