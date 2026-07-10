import Foundation
import CoreGraphics

/// Text provider for Anthropic's Messages API (`/v1/messages`). Streams via SSE
/// `content_block_delta` events. Always cloud.
struct AnthropicProvider: IntelligenceProvider {
    let baseURL: URL
    let apiKey: String
    let model: String

    var name: String { "Anthropic · \(model)" }
    let isAppleOnDevice = false
    let isLocal = false

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.
    """

    func checkAvailability() async -> Bool { !apiKey.isEmpty && !model.isEmpty }

    /// List Anthropic's available models via `GET /v1/models`. Empty on any failure.
    static func availableModels(baseURL: URL, apiKey: String) async -> [String] {
        guard !apiKey.isEmpty else { return [] }
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1/messages") { trimmed.removeLast("/v1/messages".count) }
        guard let url = URL(string: trimmed + "/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return [] }
        // API returns newest first; keep that order.
        return models.compactMap { $0["id"] as? String }
    }

    /// Build the messages URL, tolerating a base that already includes the endpoint or trailing slashes.
    static func messagesURL(base: URL) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1/messages") { s.removeLast("/v1/messages".count) }
        return URL(string: s + "/v1/messages") ?? base
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var user = prompt
        if let context, !context.isEmpty { user += "\n\n--- On-screen text ---\n\(context)" }
        return stream(messages: [["role": "user", "content": user]])
    }

    /// Native multi-turn chat. A turn with an image becomes an image content block + text
    /// (requires a vision-capable Claude — the caller routes others to a text description instead).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let wire: [[String: Any]] = messages.filter { $0.role != .system }.map { turn in
            if !turn.imageBase64s.isEmpty {
                var content: [[String: Any]] = turn.imageBase64s.map { base64 in
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
                }
                content.append(["type": "text", "text": turn.text])
                return ["role": turn.role.rawValue, "content": content]
            }
            return ["role": turn.role.rawValue, "content": turn.text]
        }
        return stream(messages: wire, system: Self.mergedSystem(from: messages))
    }

    /// Combine every system-role turn (base prompt + the conversation-memory & semantic-retrieval
    /// blocks injected by `ChatContextBuilder`) into Anthropic's top-level `system`. Using only the
    /// first system turn silently dropped that memory/recall context.
    private static func mergedSystem(from messages: [ChatTurn]) -> String {
        let systems = messages.filter { $0.role == .system && !$0.text.isEmpty }.map(\.text)
        return systems.isEmpty ? systemPrompt : systems.joined(separator: "\n\n")
    }

    // MARK: - Tool calling (industry-standard function calling)

    var supportsTools: Bool { true }

    /// Wire `messages` array (system is sent top-level, so it's excluded here).
    private func wireMessages(_ messages: [ChatTurn]) -> [[String: Any]] {
        messages.filter { $0.role != .system }.map { turn in
            if !turn.imageBase64s.isEmpty {
                var content: [[String: Any]] = turn.imageBase64s.map { base64 in
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
                }
                content.append(["type": "text", "text": turn.text])
                return ["role": turn.role.rawValue, "content": content]
            }
            return ["role": turn.role.rawValue, "content": turn.text]
        }
    }

    func respond(messages: [ChatTurn], tools: [ChatTool],
                 execute: @escaping ToolExecutor) -> AsyncThrowingStream<String, Error> {
        let system = Self.mergedSystem(from: messages)
        // Build the (non-Sendable) wire dictionaries *inside* the Task from the Sendable inputs, so
        // nothing non-Sendable crosses the task boundary.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var wire = self.wireMessages(messages)
                    let toolsWire: [[String: Any]] = tools.map {
                        ["name": $0.name, "description": $0.description, "input_schema": $0.jsonSchema]
                    }
                    for round in 0..<maxToolRounds {
                        let offerTools = round < maxToolRounds - 1
                        let result = try await self.streamMessage(
                            system: system, messages: wire, tools: offerTools ? toolsWire : [],
                            continuation: continuation)
                        guard !result.calls.isEmpty else { continuation.finish(); return }

                        // Assistant turn must echo its text + tool_use blocks; then user turn returns
                        // a tool_result block per call.
                        var assistantContent: [[String: Any]] = []
                        if !result.text.isEmpty {
                            assistantContent.append(["type": "text", "text": result.text])
                        }
                        for call in result.calls {
                            assistantContent.append([
                                "type": "tool_use", "id": call.id, "name": call.name,
                                "input": call.inputObject,
                            ])
                        }
                        wire.append(["role": "assistant", "content": assistantContent])

                        var toolResults: [[String: Any]] = []
                        for call in result.calls {
                            let output = await execute(
                                ToolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
                            toolResults.append([
                                "type": "tool_result", "tool_use_id": call.id, "content": output,
                            ])
                        }
                        wire.append(["role": "user", "content": toolResults])
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

    /// Stream one Messages call: yield text deltas live, assemble `tool_use` blocks (id/name from
    /// `content_block_start`, arguments from `input_json_delta`). Returns the text + assembled calls.
    private func streamMessage(system: String, messages: [[String: Any]], tools: [[String: Any]],
                               continuation: AsyncThrowingStream<String, Error>.Continuation)
        async throws -> (text: String, calls: [AssembledToolUse]) {
        var bodyDict: [String: Any] = [
            "model": model, "max_tokens": 1024, "stream": true, "system": system, "messages": messages,
        ]
        if !tools.isEmpty { bodyDict["tools"] = tools }
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw IntelligenceError.server("Couldn't encode the request.")
        }
        var request = URLRequest(url: Self.messagesURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = body

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server("Anthropic returned HTTP \(code). Check the API key and model.")
        }

        var text = ""
        var blocks: [Int: AssembledToolUse] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "content_block_start":
                let index = json["index"] as? Int ?? 0
                if let block = json["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use" {
                    blocks[index] = AssembledToolUse(id: block["id"] as? String ?? "",
                                                     name: block["name"] as? String ?? "")
                }
            case "content_block_delta":
                let index = json["index"] as? Int ?? 0
                guard let delta = json["delta"] as? [String: Any] else { continue }
                if let t = delta["text"] as? String, !t.isEmpty {
                    text += t; continuation.yield(t)
                } else if let partial = delta["partial_json"] as? String {
                    blocks[index]?.argumentsJSON += partial
                }
            case "message_stop":
                break
            default:
                continue
            }
        }
        let calls = blocks.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
        return (text, calls)
    }

    struct AssembledToolUse {
        var id = ""
        var name = ""
        var argumentsJSON = ""

        /// Parsed argument object for the fed-back `tool_use` block (Anthropic wants an object, not a
        /// string). Empty object on malformed/partial JSON.
        var inputObject: [String: Any] {
            guard let data = argumentsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }
    }

    private func stream(messages: [[String: Any]], system: String = systemPrompt) -> AsyncThrowingStream<String, Error> {
        // Encode up front so the (non-Sendable) message dictionaries don't cross into the Task closure.
        let body = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024, "stream": true,
            "system": system,
            "messages": messages,
        ])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let body else { throw IntelligenceError.server("Couldn't encode the request.") }
                    var request = URLRequest(url: Self.messagesURL(base: baseURL))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.httpBody = body

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw IntelligenceError.server("Anthropic returned HTTP \(code). Check the API key and model.")
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? decoder.decode(StreamEvent.self, from: data) else { continue }
                        if event.type == "message_stop" { break }
                        if let text = event.delta?.text, !text.isEmpty { continuation.yield(text) }
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
}

/// Vision via Anthropic Messages with a base64 image block (requires a vision-capable claude model).
struct AnthropicVisionProvider: VisionProvider {
    let baseURL: URL
    let apiKey: String
    let model: String

    func isAvailable() async -> Bool { !apiKey.isEmpty && !model.isEmpty }

    func describe(_ image: CGImage, prompt: String) async throws -> String {
        guard let base64 = ImageEncoder.jpegBase64(image) else {
            throw IntelligenceError.server("Couldn't encode the image.")
        }
        var request = URLRequest(url: AnthropicProvider.messagesURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let content: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
            ["type": "text", "text": prompt],
        ]
        let body: [String: Any] = [
            "model": model, "max_tokens": 1024,
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.vision.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server("Vision request returned HTTP \(code). Is \(model) vision-capable?")
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        return decoded.content.first(where: { $0.text != nil })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Wire types

private struct StreamEvent: Decodable {
    struct Delta: Decodable { let text: String? }
    let type: String
    let delta: Delta?
}

private struct MessageResponse: Decodable {
    struct Block: Decodable { let text: String? }
    let content: [Block]
}
