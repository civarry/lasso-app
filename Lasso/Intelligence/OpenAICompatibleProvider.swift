import Foundation
import CoreGraphics

/// Text provider for any OpenAI-compatible `/chat/completions` endpoint — OpenAI, Groq, OpenRouter,
/// or a custom/self-hosted base URL. Streams via SSE. Local when the base URL is localhost.
struct OpenAICompatibleProvider: IntelligenceProvider {
    let baseURL: URL
    let apiKey: String
    let model: String
    let displayName: String   // "OpenAI" / "Groq" / "Custom" …

    var name: String { "\(displayName) · \(model)" }
    let isAppleOnDevice = false
    var isLocal: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.
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

    /// Drop obvious non-chat models (embeddings, audio, image, moderation) so the picker stays useful.
    static func chatModels(_ ids: [String]) -> [String] {
        let exclude = ["embed", "whisper", "tts", "dall-e", "dalle", "moderation", "audio",
                       "image", "rerank", "stable-diffusion", "flux"]
        return ids.filter { id in
            let lower = id.lowercased()
            return !exclude.contains { lower.contains($0) }
        }.sorted()
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
            if let base64 = turn.imageBase64 {
                wire.append([
                    "role": turn.role.rawValue,
                    "content": [
                        ["type": "text", "text": turn.text],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ],
                ])
            } else {
                wire.append(["role": turn.role.rawValue, "content": turn.text])
            }
        }
        return stream(messages: wire)
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

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw IntelligenceError.server(
                            "\(displayName) HTTP \(code) at \(request.url?.absoluteString ?? "?"). "
                            + Self.hint(for: code))
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(ChatChunk.self, from: data),
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
