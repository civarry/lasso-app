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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: Self.messagesURL(base: baseURL))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    var user = prompt
                    if let context, !context.isEmpty { user += "\n\n--- On-screen text ---\n\(context)" }
                    let body: [String: Any] = [
                        "model": model, "max_tokens": 1024, "stream": true,
                        "system": Self.systemPrompt,
                        "messages": [["role": "user", "content": user]],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        let (data, response) = try await URLSession.shared.data(for: request)
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
