import Foundation
import CoreGraphics
import AppKit

/// Sends an image to a local Ollama vision model (e.g. qwen3-vl:2b) for "what is this" / describe.
/// Local + free; the image stays on the Mac. Used by the Identify pipeline.
struct OllamaVisionProvider: VisionProvider {
    let model: String
    let baseURL: URL

    init(model: String, baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    /// True if `model` is pulled and the server is up.
    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(TagList.self, from: data) else { return false }
        let base = model.split(separator: ":").first.map(String.init) ?? model
        return tags.models.contains { $0.name == model || $0.name.hasPrefix(base) }
    }

    /// Describe / identify the image. Non-streaming (we want the full description before synthesis).
    func describe(_ image: CGImage, prompt: String) async throws -> String {
        guard let base64 = ImageEncoder.jpegBase64(image) else {
            throw IntelligenceError.server("Couldn't encode the image.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        // keep_alive: 0 → unload the model right after, so it doesn't linger in RAM (memory-friendly
        // on smaller Macs). Costs a ~2s reload next time.
        let body = ChatRequest(model: model, stream: false, keep_alive: "0",
                               messages: [.init(role: "user", content: prompt, images: [base64])])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntelligenceError.server("Vision model returned HTTP \(code). Is \(model) pulled?")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let error = decoded.error { throw IntelligenceError.server(error) }
        return decoded.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String; let images: [String] }
    let model: String
    let stream: Bool
    let keep_alive: String
    let messages: [Message]
}

private struct ChatResponse: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let error: String?
}

private struct TagList: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
