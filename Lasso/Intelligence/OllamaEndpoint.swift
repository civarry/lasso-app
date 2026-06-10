import Foundation

/// Single source of truth for where the local Ollama server lives. Every normal install answers on
/// the standard `localhost:11434`, so that's the default — but a user can set a custom URL, and in
/// "Auto" mode we probe a short candidate list (custom → `OLLAMA_HOST` → localhost → 127.0.0.1) and
/// remember the one that answers. Also powers the in-app connection status (the compiled app has no
/// debug console, so users need a visible signal).
enum OllamaEndpoint {
    static let defaultURL = URL(string: "http://localhost:11434")!
    private static let customKey = "ollama.baseURL"     // user-entered URL, "" = Auto
    private static let detectedKey = "ollama.detectedURL" // last URL that answered (session cache)

    /// The user's custom URL string, or "" for Auto.
    static var customURLString: String {
        get { UserDefaults.standard.string(forKey: customKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }

    /// Effective base URL for all Ollama clients (synchronous). A valid custom URL wins; otherwise
    /// the last auto-detected URL, falling back to the standard default.
    static var baseURL: URL {
        if let custom = normalized(customURLString) { return custom }
        if let cached = UserDefaults.standard.string(forKey: detectedKey), let url = URL(string: cached) {
            return url
        }
        return defaultURL
    }

    /// Turn a loose string ("localhost:11434", "host:port", "http://…/") into a clean base URL.
    static func normalized(_ raw: String) -> URL? {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string), url.host != nil else { return nil }
        return url
    }

    /// Candidate servers to probe in Auto mode, best first.
    private static var candidates: [URL] {
        var urls: [URL] = []
        if let custom = normalized(customURLString) { urls.append(custom) }
        if let env = ProcessInfo.processInfo.environment["OLLAMA_HOST"], let u = normalized(env) {
            urls.append(u)
        }
        urls.append(defaultURL)
        urls.append(URL(string: "http://127.0.0.1:11434")!)
        return urls
    }

    /// Probe the candidates and cache the first that answers. Cheap (short timeout). Returns nil if
    /// none respond (Ollama not running / unreachable).
    @discardableResult
    static func autodetect() async -> URL? {
        for url in candidates where await isReachable(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: detectedKey)
            return url
        }
        return nil
    }

    /// True if an Ollama server answers `/api/tags` at `url`.
    static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// User-facing connection status for Settings.
    struct Status: Sendable { let ok: Bool; let url: URL; let label: String }

    static func status() async -> Status { await status(for: customURLString) }

    /// Status for a specific (possibly unsaved) custom string — empty means Auto. Lets Settings show
    /// live reachability for what the user is typing, before they Save.
    static func status(for custom: String) async -> Status {
        // Auto mode re-probes so the status reflects a server that actually answers.
        let url: URL
        if let c = normalized(custom) { url = c } else { url = await autodetect() ?? defaultURL }
        let ok = await isReachable(url)
        let host = url.host ?? url.absoluteString
        let port = url.port.map { ":\($0)" } ?? ""
        let where_ = "\(host)\(port)"
        return Status(ok: ok, url: url,
                      label: ok ? "Connected to Ollama at \(where_)"
                                : "Can't reach Ollama at \(where_) — open the Ollama app (or run `ollama serve`).")
    }
}
