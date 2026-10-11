import Foundation
import CoreGraphics

/// Text provider for any OpenAI-compatible `/chat/completions` endpoint — OpenAI, Groq, OpenRouter,
/// or a custom/self-hosted base URL. Streams via SSE. Local when the base URL is localhost.
struct OpenAICompatibleProvider: IntelligenceProvider {
    let baseURL: URL
    let apiKey: String
    let model: String
    let displayName: String   // "OpenAI" / "Groq" / "Custom" …
    /// Seconds a streaming request may go without data before it fails (`URLRequest.timeoutInterval`).
    /// The selected model keeps URLSession's usual 60; a free-model fallback candidate gets less
    /// (`FallbackDriver.candidateTimeout`), so one silent stand-in can't eat the whole fallback.
    var requestTimeout: TimeInterval = 60
    /// Whether to run the tool loop. On for the selected model (the endpoint is assumed to support it,
    /// as before); off for a fallback candidate whose model list says it can't call tools, which then
    /// answers without them instead of rejecting the request.
    var supportsToolCalls: Bool = true

    var name: String { "\(displayName) · \(model)" }
    let isAppleOnDevice = false
    /// This Mac only, the same test the connection form and the registry use (`KeysRegistry.isLocalURL`),
    /// so the privacy badge and the fallback policy never disagree about a 0.0.0.0 server.
    var isLocal: Bool { KeysRegistry.isLocalURL(baseURL.absoluteString) }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.

    Answers appear in a narrow floating panel, so write plain sentences — no tables, no headings, and \
    no LaTeX (the panel does not render math). Use a short bullet list only for genuinely parallel \
    items, and a fenced code block with a language tag for any code or command.
    """

    func checkAvailability() async -> Bool {
        !model.isEmpty && (isLocal || !apiKey.isEmpty)
    }

    /// Build the chat-completions URL, tolerating a base that already includes the endpoint (users
    /// often paste the full URL) or trailing slashes.
    static func chatCompletionsURL(base: URL) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") { s.removeLast("/chat/completions".count) }
        return URL(string: s + "/chat/completions") ?? base
    }

    /// List the models the endpoint advertises via `GET /models` (OpenAI, Groq, OpenRouter, and most
    /// compatible servers support this), filtered to chat-capable ids. Empty on any failure.
    static func availableModels(baseURL: URL, apiKey: String) async -> [String] {
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { trimmed.removeLast("/chat/completions".count) }
        guard let url = URL(string: trimmed + "/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return [] }
        return chatModels(models.compactMap { $0["id"] as? String })
    }

    /// Discover *every* model the endpoint advertises via `GET /models`, unfiltered — for the
    /// omni-router registry, which tags each model's capabilities (language / vision / embedding)
    /// itself instead of dropping non-chat models, and keeps any pricing/modality metadata the
    /// endpoint sends. nil on any failure.
    static func discoverModels(baseURL: URL, apiKey: String) async -> [RegistryModel]? {
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { trimmed.removeLast("/chat/completions".count) }
        guard let url = URL(string: trimmed + "/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return KeysRegistry.parseOpenAIModelList(data)
    }

    /// Drop obvious non-chat models (embeddings, audio, image, moderation) so the picker stays useful.
    static func chatModels(_ ids: [String]) -> [String] {
        let exclude = ["embed", "whisper", "tts", "dall-e", "dalle", "moderation", "audio",
                       "image", "rerank", "stable-diffusion", "flux"]
        return ids.filter { id in
            let lower = id.lowercased()
            return !exclude.contains { lower.contains($0) }
        }.sorted()
    }

    /// OpenRouter (and some gateways) report an upstream failure *inside* a 200 stream:
    /// `{"choices":[],"error":{"code":502,"message":"Upstream error from Nvidia: …overloaded"}}` (seen
    /// live). Ignored, the stream just ends empty: no answer, and no error for the fallback to act on.
    /// Surfaced with its status code, so it's classified like the same status on the response itself.
    static func streamError(in json: [String: Any], displayName: String) -> IntelligenceError? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        let code = (error["code"] as? Int) ?? Int(error["code"] as? String ?? "")
        let message = error["message"] as? String ?? "Upstream error."
        return .server("\(displayName) HTTP \(code.map(String.init) ?? "error") in stream. \(message)")
    }

    /// The provider's own explanation from an error response body (`{"error":{"message":…}}`), read
    /// only up to a few KB. It is what distinguishes, say, Groq's tokens-per-minute 413 (a rate limit)
    /// from a request that is simply too large, so it's appended to the error rather than dropped.
    static func errorDetail(from bytes: URLSession.AsyncBytes) async -> String? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4_096 { break }
            }
        } catch {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? json["error"] as? String
        guard let message, !message.isEmpty else { return nil }
        return String(message.prefix(300))
    }

    static func hint(for code: Int) -> String {
        switch code {
        case 401, 403: "Check the API key."
        case 404: "Check the base URL (e.g. Groq must end in /openai/v1) and the model name."
        case 429: "Rate limited — try again shortly."
        default: "Check the API key, base URL, and model."
        }
    }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var user = prompt
        if let context, !context.isEmpty { user += "\n\n--- On-screen text ---\n\(context)" }
        return stream(messages: [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": user],
        ])
    }

    /// Native multi-turn chat. A turn with an image becomes a multimodal `content` array
    /// (text + `image_url` data URL); requires a multimodal model (the caller routes others to a
    /// text description instead).
    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        var wire: [[String: Any]] = []
        if !messages.contains(where: { $0.role == .system }) {
            wire.append(["role": "system", "content": Self.systemPrompt])
        }
        for turn in messages {
            if turn.imageBase64s.isEmpty {
                wire.append(["role": turn.role.rawValue, "content": turn.text])
            } else {
                var content: [[String: Any]] = [["type": "text", "text": turn.text]]
                for base64 in turn.imageBase64s {
                    content.append(["type": "image_url",
                                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                }
                wire.append(["role": turn.role.rawValue, "content": content])
            }
        }
        return stream(messages: wire)
    }

    // MARK: - Tool calling (industry-standard function calling)

    var supportsTools: Bool { supportsToolCalls }

    /// Build the wire `messages` array (system + turns, with multimodal content for image turns).
    private func wireMessages(_ messages: [ChatTurn]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        if !messages.contains(where: { $0.role == .system }) {
            wire.append(["role": "system", "content": Self.systemPrompt])
        }
        for turn in messages {
            if turn.imageBase64s.isEmpty {
                wire.append(["role": turn.role.rawValue, "content": turn.text])
            } else {
                var content: [[String: Any]] = [["type": "text", "text": turn.text]]
                for base64 in turn.imageBase64s {
                    content.append(["type": "image_url",
                                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                }
                wire.append(["role": turn.role.rawValue, "content": content])
            }
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
                    let toolNames = Set(tools.map(\.name))
                    // Loop: stream a completion; if the model called tools, run them, append the
                    // results, and stream again. Final answer (no tool calls) streams to the user.
                    for round in 0..<maxToolRounds {
                        // On the last allowed round, drop tools so the model must answer.
                        let offerTools = round < maxToolRounds - 1
                        let calls = try await self.streamCompletion(
                            messages: wire, tools: offerTools ? toolsWire : [], toolNames: toolNames,
                            continuation: continuation)
                        guard !calls.isEmpty else { continuation.finish(); return }
                        // Tools were withdrawn and the model still only wrote a call: there is no answer.
                        // Say so, rather than finishing with an empty reply.
                        guard offerTools else {
                            throw IntelligenceError.server("\(self.displayName) kept calling tools instead of answering.")
                        }

                        // Append the assistant's tool-call message, then each tool result.
                        wire.append([
                            "role": "assistant", "content": NSNull(),
                            "tool_calls": calls.map {
                                ["id": $0.id, "type": "function",
                                 "function": ["name": $0.name, "arguments": $0.argumentsJSON]]
                            },
                        ])
                        for call in calls {
                            let result = await execute(
                                ToolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))
                            wire.append(["role": "tool", "tool_call_id": call.id, "content": result])
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

    /// Stream one chat completion: yield text deltas live, and assemble any `tool_calls` deltas.
    /// Returns the assembled tool calls (empty when the model answered directly).
    private func streamCompletion(messages: [[String: Any]], tools: [[String: Any]], toolNames: Set<String>,
                                  continuation: AsyncThrowingStream<String, Error>.Continuation)
        async throws -> [AssembledToolCall] {
        var bodyDict: [String: Any] = ["model": model, "stream": true, "messages": messages]
        if !tools.isEmpty { bodyDict["tools"] = tools; bodyDict["tool_choice"] = "auto" }
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw IntelligenceError.server("Couldn't encode the request.")
        }
        var request = URLRequest(url: Self.chatCompletionsURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = requestTimeout

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = await Self.errorDetail(from: bytes).map { " \($0)" } ?? ""
            throw IntelligenceError.server(
                "\(displayName) HTTP \(code) at \(request.url?.absoluteString ?? "?"). " + Self.hint(for: code) + detail)
        }

        var partials: [Int: AssembledToolCall] = [:]
        // Some models write the call into the text instead of `tool_calls`, including on the round where
        // tools are withdrawn, so the markup is always kept out of the reply.
        var textCalls = TextToolCallExtractor(toolNames: toolNames)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = Self.streamError(in: json, displayName: displayName) { throw error }
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                let visible = toolNames.isEmpty ? content : textCalls.consume(content)
                if !visible.isEmpty { continuation.yield(visible) }
            }
            // Assemble streamed tool_calls by index (id/name arrive once; arguments stream in pieces).
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = tc["index"] as? Int ?? 0
                    var entry = partials[index] ?? AssembledToolCall()
                    if let id = tc["id"] as? String { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { entry.name = name }
                        if let args = fn["arguments"] as? String { entry.argumentsJSON += args }
                    }
                    partials[index] = entry
                }
            }
        }
        let structured = partials.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
        let (tail, written) = textCalls.finish()
        if !tail.isEmpty { continuation.yield(tail) }
        return structured.isEmpty ? written : structured
    }

    struct AssembledToolCall: Equatable {
        var id = ""
        var name = ""
        var argumentsJSON = ""
    }

    // MARK: - Structured output (native JSON-schema mode)

    /// Strict `json_schema` first, then plain `json_object`, then nil. "OpenAI-compatible" is a wide
    /// church: Groq, OpenRouter, LM Studio and llama.cpp all differ on which response formats they
    /// accept, and an endpoint that rejects one may serve the other perfectly. Falling through the
    /// options here is what keeps the rung usable instead of all-or-nothing.
    func respondJSON(prompt: String, schemaName: String, schemaJSON: String,
                     maxTokens: Int) async throws -> String? {
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        else { return nil }

        if let strict = try await completeJSON(
            prompt: prompt, maxTokens: maxTokens,
            responseFormat: ["type": "json_schema",
                             "json_schema": ["name": schemaName, "schema": schema, "strict": true]]) {
            return strict
        }
        // `json_object` mode requires the word "json" to appear in the messages.
        return try await completeJSON(
            prompt: prompt + "\n\nReply with a single JSON object and nothing else.",
            maxTokens: maxTokens,
            responseFormat: ["type": "json_object"])
    }

    /// One non-streaming completion. Returns nil when the endpoint rejects the request (so the caller
    /// can try a simpler response format); transport failures still throw.
    private func completeJSON(prompt: String, maxTokens: Int,
                              responseFormat: [String: Any]) async throws -> String? {
        let bodyDict: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0,
            "max_tokens": maxTokens,
            "response_format": responseFormat,
            "messages": [["role": "user", "content": prompt]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }

        var request = URLRequest(url: Self.chatCompletionsURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return content
    }

    private func stream(messages: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        // Encode the body up front so the (non-Sendable) message dictionaries don't cross into the
        // stream's Task closure.
        let body = try? JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "messages": messages,
        ])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let body else { throw IntelligenceError.server("Couldn't encode the request.") }
                    var request = URLRequest(url: Self.chatCompletionsURL(base: baseURL))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = body
                    request.timeoutInterval = requestTimeout

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let detail = await Self.errorDetail(from: bytes).map { " \($0)" } ?? ""
                        throw IntelligenceError.server(
                            "\(displayName) HTTP \(code) at \(request.url?.absoluteString ?? "?"). "
                            + Self.hint(for: code) + detail)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let error = Self.streamError(in: json, displayName: displayName) { throw error }
                        guard let chunk = try? decoder.decode(ChatChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content, !delta.isEmpty else { continue }
                        continuation.yield(delta)
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

/// Some models, when offered tools, write the call into the answer text instead of the API's
/// `tool_calls` field. Seen live on OpenRouter's `nvidia/nemotron-3-super-120b-a12b:free`:
///
///     <tool_call>
///     <function=web_search>
///     <parameter=query>
///     2025 Formula 1 most recent race winner
///     </parameter>
///     </function>
///     </tool_call>
///
/// Left alone, that markup lands in the chat reply and the search never runs. This holds back anything
/// that could be the start of such a block, turns complete blocks for an offered tool into real calls,
/// and releases everything else as text. The JSON form (`<tool_call>{"name":…,"arguments":{…}}`) is
/// handled too.
struct TextToolCallExtractor {
    private static let open = "<tool_call>"
    private static let close = "</tool_call>"

    let toolNames: Set<String>
    private var held = ""
    private var calls: [OpenAICompatibleProvider.AssembledToolCall] = []

    init(toolNames: Set<String>) {
        self.toolNames = toolNames
    }

    /// Feed a content delta; returns the part that is safe to show now.
    mutating func consume(_ delta: String) -> String {
        held += delta
        var visible = ""
        while true {
            guard let start = held.range(of: Self.open) else {
                // Keep a trailing fragment that could still become "<tool_call>".
                let keep = Self.partialOpenSuffixLength(held)
                visible += held.dropLast(keep)
                held = String(held.suffix(keep))
                return visible
            }
            visible += held[..<start.lowerBound]
            guard let end = held.range(of: Self.close, range: start.upperBound..<held.endIndex) else {
                held = String(held[start.lowerBound...])
                return visible
            }
            let block = String(held[start.lowerBound..<end.upperBound])
            if let call = parse(String(held[start.upperBound..<end.lowerBound])) {
                calls.append(call)
                // The line break that followed the block was part of the markup, not the answer.
                held = String(held[end.upperBound...].drop(while: \.isWhitespace))
            } else {
                visible += block
                held = String(held[end.upperBound...])
            }
        }
    }

    /// End of stream: whatever is still held (an unclosed block, a stray "<") and the calls found.
    mutating func finish() -> (text: String, calls: [OpenAICompatibleProvider.AssembledToolCall]) {
        var text = held
        if held.hasPrefix(Self.open), let call = parse(String(held.dropFirst(Self.open.count))) {
            calls.append(call)
            text = ""
        }
        held = ""
        let trimmed = calls.isEmpty ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, calls)
    }

    private static func partialOpenSuffixLength(_ text: String) -> Int {
        for length in stride(from: min(open.count - 1, text.count), to: 0, by: -1)
        where open.hasPrefix(String(text.suffix(length))) {
            return length
        }
        return 0
    }

    private func parse(_ body: String) -> OpenAICompatibleProvider.AssembledToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        var arguments: [String: Any] = [:]
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            name = json["name"] as? String
            arguments = (json["arguments"] as? [String: Any]) ?? (json["parameters"] as? [String: Any]) ?? [:]
        } else if let fn = trimmed.range(of: #"<function=([^>]+)>"#, options: .regularExpression) {
            name = String(trimmed[fn].dropFirst("<function=".count).dropLast())
            let pattern = try? NSRegularExpression(pattern: #"<parameter=([^>]+)>(.*?)</parameter>"#,
                                                   options: [.dotMatchesLineSeparators])
            let ns = trimmed as NSString
            for match in pattern?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? [] {
                arguments[ns.substring(with: match.range(at: 1))] =
                    ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let name, toolNames.contains(name),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let argumentsJSON = String(data: data, encoding: .utf8) else { return nil }
        return .init(id: "text_call_\(calls.count + 1)", name: name, argumentsJSON: argumentsJSON)
    }
}

/// Vision via the same OpenAI-compatible endpoint (requires a multimodal model, e.g. gpt-4o).
struct OpenAICompatibleVisionProvider: VisionProvider {
    let baseURL: URL
    let apiKey: String
    let model: String

    func isAvailable() async -> Bool {
        guard !model.isEmpty else { return false }
        if let host = baseURL.host?.lowercased(), host == "localhost" || host == "127.0.0.1" { return true }
        return !apiKey.isEmpty
    }

    func describe(_ image: CGImage, prompt: String) async throws -> String {
        guard let base64 = ImageEncoder.jpegBase64(image) else {
            throw IntelligenceError.server("Couldn't encode the image.")
        }
        var request = URLRequest(url: OpenAICompatibleProvider.chatCompletionsURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 60

        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
        ]
        let body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.vision.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server(
                "Vision HTTP \(code) at \(request.url?.absoluteString ?? "?"). "
                + (code == 404 ? "Check the base URL and that \(model) is a multimodal model." : OpenAICompatibleProvider.hint(for: code)))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Wire types

private struct ChatChunk: Decodable {
    struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
    let choices: [Choice]
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
    let choices: [Choice]
}
