import Foundation

/// Lists models actually installed in the local Ollama (`ollama list` / GET /api/tags), so Settings
/// can offer a real selection instead of a hardcoded model name.
enum OllamaModels {
    static func installed(baseURL: URL = URL(string: "http://localhost:11434")!) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Classification & auto-pick (so we never depend on a hardcoded model name)

    static func isEmbedding(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("embed") || n.contains("nomic") || n.contains("bge")
    }

    static func isVision(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("-vl") || n.contains("vl:") || n.contains("vision")
            || n.contains("llava") || n.contains("moondream") || n.contains("minicpm-v")
    }

    /// Best installed chat/text model (excludes embedding + vision), preferring known families.
    static func bestTextModel(_ models: [String]) -> String? {
        let chat = models.filter { !isEmbedding($0) && !isVision($0) }
        let prefs = ["qwen3", "qwen2.5", "llama3", "llama", "gemma", "mistral", "phi"]
        for pref in prefs { if let m = chat.first(where: { $0.lowercased().contains(pref) }) { return m } }
        return chat.first
    }

    /// Best installed vision model, preferring known families.
    static func bestVisionModel(_ models: [String]) -> String? {
        let vision = models.filter { isVision($0) }
        let prefs = ["qwen3-vl", "qwen2.5-vl", "minicpm-v", "llava", "moondream", "llama3.2-vision"]
        for pref in prefs { if let m = vision.first(where: { $0.lowercased().contains(pref) }) { return m } }
        return vision.first
    }

    /// Best installed embedding model (for relevance ranking).
    static func bestEmbeddingModel(_ models: [String]) -> String? {
        models.first(where: isEmbedding)
    }
}
