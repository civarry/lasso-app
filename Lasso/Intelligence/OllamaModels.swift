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
}
