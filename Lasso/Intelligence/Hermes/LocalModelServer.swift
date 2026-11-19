import Foundation
import MLXLMCommon
import Network

/// Serves Lasso's MLX model to Lasso's own Hermes, so the Agent thinks with the model chosen in Lasso
/// instead of falling back to Hermes's own (often a cloud model).
///
/// MLX runs inside Lasso, and Hermes is a separate program that only talks to models over HTTP. This is
/// the smallest OpenAI-compatible server Hermes needs: `GET /v1/models` (with the context window, which
/// Hermes requires to be at least 64K) and `POST /v1/chat/completions`, streamed or not, with tool calls.
/// Loopback only, a fresh port and a random bearer token per launch, so nothing else on the Mac (and
/// nothing off it) can use the model. One generation at a time: a second request waits its turn.
final class LocalModelServer: @unchecked Sendable {
    static let shared = LocalModelServer()

    /// Bearer token Hermes must send; new every launch, never stored.
    let token = UUID().uuidString
    private let queue = DispatchQueue(label: "lasso.local-model-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: Int?
    private let turns = Turnstile()
    private var servedModel = MLXProvider.defaultModelID

    /// The base URL Hermes should use (`http://127.0.0.1:<port>/v1`) for `model`, starting the server
    /// if needed. Switching models needs no restart: the next request uses the new one.
    func start(model: String) async throws -> URL {
        lock.withLock { servedModel = model.isEmpty ? MLXProvider.defaultModelID : model }
        if let port = lock.withLock({ boundPort }) { return Self.baseURL(port) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener; self.boundPort = port }
        Log.app.notice("model server · serving MLX to Hermes on 127.0.0.1:\(port, privacy: .public)")
        return Self.baseURL(port)
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil; self.boundPort = nil }
            return self.listener
        }
        listener?.cancel()
    }

    static func baseURL(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 64 << 20 { connection.cancel(); return }
            if let request = HTTPRequest.parse(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let writer = ResponseWriter(connection)
        guard request.headers["authorization"] == "Bearer \(token)" else {
            await writer.json(status: 401, OpenAIBridge.error("Missing or wrong API key."))
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            await writer.json(status: 200, OpenAIBridge.models(id: currentModel(),
                                                               context: MLXProvider.contextWindow(currentModel())))
        case ("POST", "/v1/chat/completions"):
            await completions(request, writer)
        default:
            await writer.json(status: 404, OpenAIBridge.error("Not found: \(request.method) \(request.path)"))
        }
    }

    private func currentModel() -> String { lock.withLock { servedModel } }

    private func completions(_ request: HTTPRequest, _ writer: ResponseWriter) async {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawMessages = body["messages"] as? [[String: Any]] else {
            await writer.json(status: 400, OpenAIBridge.error("Expected a JSON body with messages."))
            return
        }
        let model = currentModel()
        let messages = OpenAIBridge.templateMessages(rawMessages)
        let tools = OpenAIBridge.tools(body["tools"])
        let stream = body["stream"] as? Bool ?? false
        let maxTokens = (body["max_completion_tokens"] as? Int) ?? (body["max_tokens"] as? Int) ?? 4096
        let temperature = Float((body["temperature"] as? Double) ?? 0.6)
        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"

        await turns.run {
            if stream { await writer.startEventStream() }
            var text = ""
            var calls: [(name: String, args: String)] = []
            var usage: (prompt: Int, completion: Int, seconds: Double)?
            let generation = MLXProvider.serve(modelID: model, messages: messages, tools: tools,
                                               maxTokens: maxTokens, temperature: temperature)
            let watcher = Task { await writer.waitUntilClosed() }
            do {
                for try await event in generation {
                    if writer.isClosed { break }   // Hermes hung up (the user pressed Stop)
                    switch event {
                    case .text(let piece):
                        text += piece
                        if stream { await writer.event(OpenAIBridge.chunk(id: id, model: model, content: piece)) }
                    case .toolCall(let name, let args):
                        calls.append((name, args))
                    case .prompt: break
                    case .usage(let prompt, let completion, let seconds):
                        usage = (prompt, completion, seconds)
                    }
                }
            } catch {
                Log.app.error("model server · generation failed: \(String(describing: error), privacy: .public)")
                if stream {
                    await writer.event(OpenAIBridge.error(error.localizedDescription))
                    await writer.close()
                } else {
                    await writer.json(status: 500, OpenAIBridge.error(error.localizedDescription))
                }
                watcher.cancel()
                return
            }
            watcher.cancel()
            if let usage {
                Log.app.notice("model server · \(usage.prompt, privacy: .public) prompt tokens read in \(String(format: "%.1f", usage.seconds), privacy: .public)s, \(usage.completion, privacy: .public) written, \(calls.count, privacy: .public) tool calls")
            }
            let callIDs = calls.map { _ in "call_\(UUID().uuidString.prefix(8))" }
            let finish = calls.isEmpty ? "stop" : "tool_calls"
            if stream {
                if !calls.isEmpty {
                    await writer.event(OpenAIBridge.toolCallChunk(id: id, model: model, calls: calls, ids: callIDs))
                }
                await writer.event(OpenAIBridge.finishChunk(id: id, model: model, reason: finish, usage: usage))
                await writer.done()
            } else {
                await writer.json(status: 200, OpenAIBridge.completion(
                    id: id, model: model, content: text, calls: calls, ids: callIDs, reason: finish, usage: usage))
            }
        }
    }
}

// MARK: - OpenAI wire format

/// Translation between OpenAI chat-completions JSON and what MLX's chat templates take. Pure.
enum OpenAIBridge {
    /// OpenAI messages → chat-template messages: text parts joined, `developer` treated as `system`,
    /// tool-call arguments decoded from their JSON string into a dictionary (Qwen's template iterates
    /// them), `null` content dropped.
    static func templateMessages(_ raw: [[String: Any]]) -> [[String: any Sendable]] {
        foldSystemMessages(raw.map { message in
            var out: [String: any Sendable] = [:]
            let role = message["role"] as? String ?? "user"
            out["role"] = role == "developer" ? "system" : role
            out["content"] = text(of: message["content"])
            if let id = message["tool_call_id"] as? String { out["tool_call_id"] = id }
            if let name = message["name"] as? String { out["name"] = name }
            if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                out["tool_calls"] = calls.map { call -> [String: any Sendable] in
                    let function = call["function"] as? [String: Any] ?? [:]
                    var arguments: [String: any Sendable] = [:]
                    if let string = function["arguments"] as? String,
                       let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] {
                        arguments = sendable(object) as? [String: any Sendable] ?? [:]
                    } else if let object = function["arguments"] as? [String: Any] {
                        arguments = sendable(object) as? [String: any Sendable] ?? [:]
                    }
                    return ["id": call["id"] as? String ?? "",
                            "type": "function",
                            "function": ["name": function["name"] as? String ?? "",
                                         "arguments": arguments] as [String: any Sendable]]
                }
            }
            return out
        })
    }

    /// Chat templates (Qwen's among them) refuse a system message anywhere but first; Hermes can add
    /// one later in a conversation. Later ones are appended to the first, in order.
    static func foldSystemMessages(_ messages: [[String: any Sendable]]) -> [[String: any Sendable]] {
        let system = messages.filter { $0["role"] as? String == "system" }
        guard !system.isEmpty else { return messages }
        let merged = system.compactMap { $0["content"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return [["role": "system", "content": merged]] + messages.filter { $0["role"] as? String != "system" }
    }

    /// Message content as plain text: a string, or the text parts of a parts array.
    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    /// The request's `tools`, as MLX tool specs (same shape: `{"type":"function","function":{...}}`).
    static func tools(_ raw: Any?) -> [ToolSpec]? {
        guard let list = raw as? [[String: Any]], !list.isEmpty else { return nil }
        return list.compactMap { sendable($0) as? [String: any Sendable] }
    }

    /// JSON values from `JSONSerialization` as Sendable values the template engine understands; nulls
    /// are dropped.
    static func sendable(_ value: Any) -> (any Sendable)? {
        switch value {
        case let dict as [String: Any]:
            var out: [String: any Sendable] = [:]
            for (key, element) in dict { if let v = sendable(element) { out[key] = v } }
            return out
        case let array as [Any]:
            return array.compactMap { sendable($0) }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if CFNumberIsFloatType(number) { return number.doubleValue }
            return number.intValue
        case let string as String:
            return string
        default:
            return nil
        }
    }

    static func models(id: String, context: Int?) -> [String: Any] {
        var model: [String: Any] = ["id": id, "object": "model", "owned_by": "lasso"]
        if let context { model["context_length"] = context }
        return ["object": "list", "data": [model]]
    }

    static func error(_ message: String) -> [String: Any] {
        ["error": ["message": message, "type": "lasso_model_server"]]
    }

    private static func base(_ id: String, _ model: String, object: String) -> [String: Any] {
        ["id": id, "object": object, "created": Int(Date().timeIntervalSince1970), "model": model]
    }

    static func chunk(id: String, model: String, content: String) -> [String: Any] {
        var out = base(id, model, object: "chat.completion.chunk")
        out["choices"] = [["index": 0, "delta": ["role": "assistant", "content": content], "finish_reason": NSNull()]]
        return out
    }

    static func toolCallChunk(id: String, model: String, calls: [(name: String, args: String)], ids: [String]) -> [String: Any] {
        var out = base(id, model, object: "chat.completion.chunk")
        let deltas = calls.enumerated().map { index, call -> [String: Any] in
            ["index": index, "id": ids[index], "type": "function",
             "function": ["name": call.name, "arguments": call.args]]
        }
        out["choices"] = [["index": 0, "delta": ["role": "assistant", "tool_calls": deltas], "finish_reason": NSNull()]]
        return out
    }

    static func finishChunk(id: String, model: String, reason: String,
                            usage: (prompt: Int, completion: Int, seconds: Double)?) -> [String: Any] {
        var out = base(id, model, object: "chat.completion.chunk")
        out["choices"] = [["index": 0, "delta": [String: Any](), "finish_reason": reason]]
        if let usage { out["usage"] = usageJSON(usage) }
        return out
    }

    static func completion(id: String, model: String, content: String, calls: [(name: String, args: String)],
                           ids: [String], reason: String,
                           usage: (prompt: Int, completion: Int, seconds: Double)?) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty {
            message["tool_calls"] = calls.enumerated().map { index, call -> [String: Any] in
                ["id": ids[index], "type": "function", "function": ["name": call.name, "arguments": call.args]]
            }
        }
        var out = base(id, model, object: "chat.completion")
        out["choices"] = [["index": 0, "message": message, "finish_reason": reason]]
        if let usage { out["usage"] = usageJSON(usage) }
        return out
    }

    private static func usageJSON(_ usage: (prompt: Int, completion: Int, seconds: Double)) -> [String: Any] {
        ["prompt_tokens": usage.prompt, "completion_tokens": usage.completion,
         "total_tokens": usage.prompt + usage.completion]
    }
}

// MARK: - HTTP plumbing

/// One HTTP/1.1 request, parsed once the headers and the whole body (Content-Length) have arrived.
struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]   // lowercased names
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let path = String(start[1]).split(separator: "?").first.map(String.init) ?? "/"
        return HTTPRequest(method: String(start[0]), path: path, headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

/// Writes one response and closes the connection (no keep-alive: Hermes reconnects per request).
private final class ResponseWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    var isClosed: Bool { lock.withLock { closed } }

    func json(status: Int, _ object: [String: Any]) async {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        await send(Data(head.utf8) + body)
        await close()
    }

    func startEventStream() async {
        await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
    }

    func event(_ object: [String: Any]) async {
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        await send(Data("data: ".utf8) + json + Data("\n\n".utf8))
    }

    func done() async {
        await send(Data("data: [DONE]\n\n".utf8))
        await close()
    }

    func close() async {
        let wasOpen = lock.withLock { () -> Bool in defer { closed = true }; return !closed }
        if wasOpen { connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() }) }
    }

    /// Returns when the client goes away (marks the writer closed so generation stops).
    func waitUntilClosed() async {
        while !Task.isCancelled {
            switch connection.state {
            case .failed, .cancelled:
                lock.withLock { closed = true }
                return
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func send(_ data: Data) async {
        guard !isClosed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.lock.withLock { self?.closed = true } }
                continuation.resume()
            })
        }
    }
}

/// Runs one operation at a time, in arrival order.
private actor Turnstile {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @Sendable () async -> Void) async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        await operation()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// A flag that can be claimed once (a continuation resumes exactly once).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
