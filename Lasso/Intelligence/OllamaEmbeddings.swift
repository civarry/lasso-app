import Foundation

/// Local text embeddings via Ollama (e.g. nomic-embed-text) for semantic relevance ranking of
/// Identify's web results — like all-MiniLM-L6-v2, but using a model the user already has.
struct OllamaEmbeddings {
    let model: String
    let baseURL: URL

    init(model: String = "nomic-embed-text", baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    /// Embed a batch of strings. Returns nil if the model/server isn't available.
    func embed(_ inputs: [String]) async -> [[Double]]? {
        guard !inputs.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(EmbedRequest(model: model, input: inputs))

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              decoded.embeddings.count == inputs.count else { return nil }
        return decoded.embeddings
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices { dot += a[i] * b[i]; normA += a[i] * a[i]; normB += b[i] * b[i] }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}

private struct EmbedRequest: Encodable { let model: String; let input: [String] }
private struct EmbedResponse: Decodable { let embeddings: [[Double]] }
