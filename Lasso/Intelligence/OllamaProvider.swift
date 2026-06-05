import Foundation

/// Talks to a local Ollama server (default `http://localhost:11434`) for the "bigger model"
/// path — e.g. `gpt-oss:20b`. Runs on this machine; no data leaves the Mac, but it is a separate
/// process from the app (hence `isAppleOnDevice == false`).
struct OllamaProvider: IntelligenceProvider {
    let model: String
    let baseURL: URL

    var name: String { "Ollama · \(model)" }
    let isAppleOnDevice = false

    init(model: String = "gpt-oss:20b",
         baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    private static let systemPrompt = """
    You help the user understand and act on text they selected on their screen. Be concise and \
    accurate. When on-screen text is provided, ground your answer in it.
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeChatRequest(prompt: prompt, context: context)
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

    private func makeChatRequest(prompt: String, context: String?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent = prompt
        if let context, !context.isEmpty {
            userContent += "\n\n--- On-screen text ---\n\(context)"
        }
        let body = ChatRequest(
            model: model,
            stream: true,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: userContent),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - Wire types

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let stream: Bool
    let messages: [Message]
}

private struct ChatChunk: Decodable {
    struct Message: Decodable { let role: String?; let content: String? }
    let message: Message?
    let done: Bool
    let error: String?
}
