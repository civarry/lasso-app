import Foundation

/// An Ollama model for the Agent with a context window Hermes can work in.
///
/// Ollama loads a model with 4,096 tokens of context unless told otherwise, and its OpenAI-compatible
/// endpoint, the one Hermes uses, ignores `options.num_ctx` (Ollama 0.40, checked: the model stayed at
/// 4,096). Hermes's ~13.5K-token setup then fails every turn ("Context length exceeded … cannot compress
/// further"). So the Agent gets a variant of the chosen model whose own parameters set `num_ctx`
/// (`POST /api/create` with `from`): it shares the model's files, costs no download or disk, and is made
/// once per model. Lasso's regular chat keeps using the model itself (it sends `num_ctx` natively).
enum OllamaAgentModel {
    /// Hermes refuses models under 64K; this is the window its own error message recommends.
    static let contextTokens = 65_536
    private static let namespace = "lasso-agent"

    /// `lasso-agent/<model>` with characters Ollama names allow.
    static func name(for base: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let slug = String(base.lowercased().map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return "\(namespace)/\(slug.prefix(80))"
    }

    /// The variant's name, creating it if it's missing; nil if Ollama couldn't make it (the caller then
    /// uses the model itself).
    static func ensure(_ base: String, baseURL: URL = OllamaEndpoint.baseURL) async -> String? {
        guard !base.isEmpty else { return nil }
        if base.hasPrefix(namespace + "/") { return base }
        let variant = name(for: base)
        let window = min(contextTokens, await OllamaEndpoint.modelInfo(base, baseURL: baseURL).context ?? contextTokens)
        if await numCtx(of: variant, baseURL: baseURL) == window { return variant }
        let body: [String: Any] = ["model": variant, "from": base, "parameters": ["num_ctx": window], "stream": false]
        guard let (_, status) = await post("api/create", body, baseURL: baseURL, timeout: 60), status == 200,
              await numCtx(of: variant, baseURL: baseURL) == window else {
            Log.chat.error("hermes · couldn't make an Agent variant of \(base, privacy: .public) with \(window, privacy: .public) tokens of context")
            return nil
        }
        Log.chat.notice("hermes · made \(variant, privacy: .public) (\(window, privacy: .public) tokens of context) for the Agent")
        return variant
    }

    /// `num_ctx` from a model's own parameters, if it has one.
    static func numCtx(of model: String, baseURL: URL) async -> Int? {
        guard let (data, status) = await post("api/show", ["model": model], baseURL: baseURL, timeout: 5), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseNumCtx(json["parameters"] as? String ?? "")
    }

    /// `num_ctx 65536` from `/api/show`'s `parameters` text. Internal for tests.
    static func parseNumCtx(_ parameters: String) -> Int? {
        for line in parameters.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "num_ctx", let n = Int(parts[parts.count - 1]) { return n }
        }
        return nil
    }

    private static func post(_ path: String, _ body: [String: Any], baseURL: URL, timeout: TimeInterval)
        async -> (Data, Int)? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout
        guard let (out, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (out, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
