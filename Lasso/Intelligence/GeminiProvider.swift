import Foundation
import CoreGraphics

/// Google's **native** Gemini API (`generativelanguage.googleapis.com/v1beta`), not the OpenAI
/// compatibility layer.
///
/// The two are kept deliberately separate: a connection whose kind is `.openAICompatible` and whose
/// base URL happens to be Google's `/v1beta/openai/` shim still goes through
/// `OpenAICompatibleProvider` and `/chat/completions`, exactly as before. This type speaks the native
/// wire format instead — `:generateContent`, `contents`/`parts`, `x-goog-api-key` — so nothing about
/// it is a redirected OpenAI request.
///
/// Differences from OpenAI's shape that this has to reconcile:
/// - the system prompt is a top-level `systemInstruction`, not a message with `role: "system"`
/// - the assistant role is called `model`
/// - images are `inlineData` parts, not `image_url` data URLs
/// - the endpoint carries the model id and the *method*, so there's one URL per call kind
enum GeminiAPI {
    /// Fixed by the provider — a Gemini connection never asks the user for a base URL.
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    /// Model ids come back from `/models` fully qualified ("models/gemini-2.0-flash"), and the user
    /// may also have one stored in that form from the OpenAI-compat layer. Both must produce the same
    /// URL, so strip the prefix before rebuilding the path.
    static func bareModelID(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    static func endpoint(model: String, method: String, query: String = "") -> URL? {
        URL(string: "\(baseURL)/models/\(bareModelID(model)):\(method)\(query)")
    }

    static func request(_ url: URL, apiKey: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout
        request.httpBody = body
        return request
    }

    static func hint(for code: Int) -> String {
        switch code {
        case 400: "Check the model name."
        case 401, 403: "Check the Gemini API key."
        case 404: "That model isn't available to this key."
        case 429: "Rate limited — try again shortly."
        default: "Check the Gemini API key and model."
        }
    }

    /// The models this key can use, as fully-qualified ids. Only those that can actually serve a
    /// request are returned — Gemini also lists retrieval-only models (`aqa`) that would otherwise
    /// show up in the picker as dead entries.
    static func availableModels(apiKey: String) async -> [String] {
        guard !apiKey.isEmpty, let url = URL(string: "\(baseURL)/models?pageSize=200") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        let usable = Set(["generateContent", "embedContent", "batchEmbedContents"])
        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String else { return nil }
            let methods = Set(model["supportedGenerationMethods"] as? [String] ?? [])
            return methods.isDisjoint(with: usable) ? nil : name
        }.sorted()
    }

    /// The same list as `availableModels`, as registry entries carrying the input limit Gemini
    /// reports. Gemini's list carries no pricing; `FreeTierRules` applies Google's documented free
    /// plan afterwards. nil on any failure.
    static func discoverModels(apiKey: String) async -> [RegistryModel]? {
        guard !apiKey.isEmpty, let url = URL(string: "\(baseURL)/models?pageSize=200") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        let usable = Set(["generateContent", "embedContent", "batchEmbedContents"])
        return models.compactMap { entry -> RegistryModel? in
            guard let name = entry["name"] as? String else { return nil }
            let methods = Set(entry["supportedGenerationMethods"] as? [String] ?? [])
            guard !methods.isDisjoint(with: usable) else { return nil }
            var model = RegistryModel(name: name)
            if let limit = entry["inputTokenLimit"] as? Int, limit > 0 { model.contextTokens = limit }
            return model
        }.sorted { $0.name < $1.name }
    }

    /// Split `ChatTurn`s into Gemini's shape: a top-level system instruction plus `contents` whose
    /// roles are `user` / `model`.
    static func wire(_ messages: [ChatTurn], fallbackSystem: String) -> (system: String, contents: [[String: Any]]) {
        var system = messages.first { $0.role == .system }?.text ?? fallbackSystem
        if system.isEmpty { system = fallbackSystem }
        var contents: [[String: Any]] = []
        for turn in messages where turn.role != .system {
            var parts: [[String: Any]] = []
            if !turn.text.isEmpty { parts.append(["text": turn.text]) }
            for base64 in turn.imageBase64s {
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": base64]])
            }
            guard !parts.isEmpty else { continue }
            contents.append(["role": turn.role == .assistant ? "model" : "user", "parts": parts])
        }
        return (system, contents)
    }

    /// Pull the text out of a `generateContent` payload (streamed chunk or one-shot response).
    static func text(in json: [String: Any]) -> String {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}

// MARK: - Text

struct GeminiProvider: IntelligenceProvider {
    let apiKey: String
    let model: String
    /// The connection's friendly name, so errors and the privacy badge name the endpoint the user
    /// configured rather than a generic "Gemini".
    var displayName: String = "Google Gemini"
    /// Seconds the stream may go without data before it fails. Shorter for a free-model fallback
    /// candidate (`FallbackDriver.candidateTimeout`) than for the selected model.
    var requestTimeout: TimeInterval = 60

    var name: String { "\(displayName) · \(GeminiAPI.bareModelID(model))" }
    let isAppleOnDevice = false
    let isLocal = false

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.

    Answers appear in a narrow floating panel, so write plain sentences — no tables, no headings, and \
    no LaTeX (the panel does not render math). Use a short bullet list only for genuinely parallel \
    items, and a fenced code block with a language tag for any code or command.
    """

    func checkAvailability() async -> Bool { !apiKey.isEmpty && !model.isEmpty }

    func respond(prompt: String, context: String?) -> AsyncThrowingStream<String, Error> {
        var user = prompt
        if let context, !context.isEmpty { user += "\n\n--- On-screen text ---\n\(context)" }
        return stream(system: Self.systemPrompt,
                      contents: [["role": "user", "parts": [["text": user]]]])
    }

    func respond(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let wire = GeminiAPI.wire(messages, fallbackSystem: Self.systemPrompt)
        return stream(system: wire.system, contents: wire.contents)
    }

    /// Native structured output: Gemini takes `responseMimeType`, and its `responseSchema` is an
    /// OpenAPI subset that rejects some JSON Schema the callers emit (`additionalProperties`, `$defs`).
    /// Constraining the mime type and carrying the schema in the prompt is the reliable combination —
    /// and `StructuredRunner` drops a rung on its own if the result doesn't parse.
    func respondJSON(prompt: String, schemaName: String, schemaJSON: String,
                     maxTokens: Int) async throws -> String? {
        let instruction = """
        \(prompt)

        Reply with a single JSON object named "\(schemaName)" conforming to this schema. \
        No prose, no code fence.
        \(schemaJSON)
        """
        let body = try? JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": Self.systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": instruction]]]],
            "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": maxTokens],
        ])
        guard let body, let url = GeminiAPI.endpoint(model: model, method: "generateContent") else {
            return nil
        }
        let request = GeminiAPI.request(url, apiKey: apiKey, body: body, timeout: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let text = GeminiAPI.text(in: json)
        return text.isEmpty ? nil : text
    }

    /// SSE stream of `:streamGenerateContent`. Each `data:` line is a full payload (not a delta patch
    /// like OpenAI's), so the text in each chunk is already the increment to append.
    private func stream(system: String, contents: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        // Encode up front so the non-Sendable dictionaries never cross into the Task closure.
        let body = try? JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
        ])
        let url = GeminiAPI.endpoint(model: model, method: "streamGenerateContent", query: "?alt=sse")
        let key = apiKey
        let label = displayName
        let timeout = requestTimeout

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let body, let url else {
                        throw IntelligenceError.server("Couldn't encode the Gemini request.")
                    }
                    let request = GeminiAPI.request(url, apiKey: key, body: body, timeout: timeout)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw IntelligenceError.server(
                            "\(label) HTTP \(code). " + GeminiAPI.hint(for: code))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]",
                              let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        let delta = GeminiAPI.text(in: json)
                        if !delta.isEmpty { continuation.yield(delta) }
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

// MARK: - Vision

/// Images through the same native endpoint: an `inlineData` part alongside the prompt. Needed because
/// Gemini connections contribute vision-capable models to the shared picker, so the Image role can
/// resolve to one — routing that through the OpenAI-compatible vision provider would post an
/// `image_url` payload to an endpoint that doesn't accept it.
struct GeminiVisionProvider: VisionProvider {
    let apiKey: String
    let model: String

    func isAvailable() async -> Bool { !apiKey.isEmpty && !model.isEmpty }

    func describe(_ image: CGImage, prompt: String) async throws -> String {
        guard let base64 = ImageEncoder.jpegBase64(image) else {
            throw IntelligenceError.server("Couldn't encode the image.")
        }
        let body = try? JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [
                ["text": prompt],
                ["inlineData": ["mimeType": "image/jpeg", "data": base64]],
            ]]],
        ])
        guard let body, let url = GeminiAPI.endpoint(model: model, method: "generateContent") else {
            throw IntelligenceError.server("Couldn't encode the Gemini request.")
        }
        let request = GeminiAPI.request(url, apiKey: apiKey, body: body, timeout: 60)
        let (data, response) = try await URLSession.vision.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server("Gemini HTTP \(code). " + GeminiAPI.hint(for: code))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntelligenceError.server("Gemini returned an unreadable response.")
        }
        let text = GeminiAPI.text(in: json)
        guard !text.isEmpty else {
            throw IntelligenceError.server("Gemini returned no description for the image.")
        }
        return text
    }
}

// MARK: - Embeddings

/// Chat semantic memory through `:batchEmbedContents`. One request for the whole batch, and the
/// response preserves request order, so no re-sorting is needed (unlike OpenAI's indexed items).
struct GeminiEmbedder: ChatEmbedder {
    let apiKey: String
    let model: String
    var label: String { "Gemini · \(GeminiAPI.bareModelID(model))" }

    func embed(_ texts: [String]) async -> [[Double]]? {
        guard !texts.isEmpty, !apiKey.isEmpty, !model.isEmpty else { return texts.isEmpty ? [] : nil }
        let qualified = "models/\(GeminiAPI.bareModelID(model))"
        let requests = texts.map { text in
            ["model": qualified, "content": ["parts": [["text": text]]]] as [String: Any]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["requests": requests]),
              let url = GeminiAPI.endpoint(model: model, method: "batchEmbedContents") else { return nil }
        let request = GeminiAPI.request(url, apiKey: apiKey, body: body, timeout: 20)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[String: Any]],
              embeddings.count == texts.count else { return nil }
        let vectors = embeddings.compactMap { $0["values"] as? [Double] }
        return vectors.count == texts.count ? vectors : nil
    }
}
