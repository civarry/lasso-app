import Foundation

/// A "bring your own tool" add-on service the user can connect — the building blocks of the
/// Connectors store. Each connector is self-describing (name, summary, setup guide) and
/// self-validating (a `test` closure), and the app works with any combination of them connected or
/// none at all. The model engine (Apple / Ollama / cloud) is chosen separately on the Intelligence
/// tab; connectors are the optional enhancers (web search, reverse-image, search APIs).
///
/// Adding a new integration is a single entry in `Connectors.all` — no UI changes — so the store is
/// future-proof and Lego-like.
struct Connector: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String                // SF Symbol fallback (offline / local-only)
    let iconDomain: String?         // brand domain — its real logo is shown via the favicon service
    let usesImage: Bool             // true = analyses the picture itself; false = text web search
    let summary: String             // one-line "what it does"
    let leavesDevice: Bool          // makes off-device network calls (paused in local-only mode)
    let enabledKey: String          // UserDefaults bool backing the on/off toggle
    let defaultEnabled: Bool
    let keyAccount: String?         // Keychain account for the API key; nil = keyless
    let guide: SetupGuide
    /// Validate the staged config (key passed in, since it may be unsaved). Reuses the providers'
    /// real endpoints. `@Sendable` for Swift 6 strict concurrency.
    let test: @Sendable (_ key: String) async -> ConnectionTest.Outcome

    var requiresKey: Bool { keyAccount != nil }
}

/// A short, numbered "how to connect this" walkthrough shown inline on the connector card.
struct SetupGuide: Sendable {
    let steps: [Step]
    let note: String?

    struct Step: Sendable, Identifiable {
        let id = UUID()
        let text: String
        let link: URL?
        let linkLabel: String?

        init(_ text: String, link: String? = nil, linkLabel: String? = nil) {
            self.text = text
            self.link = link.flatMap { URL(string: $0) }
            self.linkLabel = linkLabel
        }
    }

    init(_ steps: [Step], note: String? = nil) {
        self.steps = steps
        self.note = note
    }
}

// MARK: - State helpers (shared with the runtime via the same UserDefaults / Keychain keys)

extension Connector {
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    /// The stored API key, if any (migrating from any legacy UserDefaults key).
    func key() -> String {
        guard let keyAccount else { return "" }
        return Keychain.getMigrating(keyAccount, legacyDefaultsKey: keyAccount) ?? ""
    }

    /// Keyless connectors are always "configured"; keyed ones need a key.
    func isConfigured() -> Bool { !requiresKey || !key().isEmpty }

    /// Whether this connector should actually be used right now.
    func isActive() -> Bool {
        guard isEnabled, isConfigured() else { return false }
        return !leavesDevice || !PrivacyMode.localOnly
    }
}

/// The catalog. Add an integration here and it appears in the store automatically.
enum Connectors {
    /// The built-in, keyless one. Everything optional (Tavily, SerpApi, any other search) is a package:
    /// see `docs/PACKAGES.md` and `PackageStore`.
    static let all: [Connector] = [webSearch]

    static func by(id: String) -> Connector? { all.first { $0.id == id } }

    // MARK: Built-in: web search (keyless)

    static let webSearch = Connector(
        id: "webSearch",
        name: "Web search",
        icon: "globe",
        iconDomain: "duckduckgo.com",
        usesImage: false,
        summary: "Text web search (Wikipedia, DuckDuckGo, Reddit) for context. No account needed.",
        leavesDevice: true,
        enabledKey: "imageSearch.enabled",
        defaultEnabled: true,
        keyAccount: nil,
        guide: SetupGuide([
            .init("On by default. It uses free public sources over plain HTTP (no embedded browser)."),
            .init("Optional: add a search package (Tavily, SerpApi or your own) in Settings › Packages for stronger, ranked results."),
        ], note: "Leaves your Mac. Paused automatically in local-only mode."),
        test: { _ in
            await ConnectorTests.get(
                "https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json",
                userAgent: "Lasso/0.1 (connector test)",
                okNote: "Reachable")
        })

}

// MARK: - Test helpers (lightweight URLSession probes; reused by the catalog's `test` closures)

enum ConnectorTests {
    private static func ms(since start: Date) -> Int { max(1, Int(Date().timeIntervalSince(start) * 1000)) }

    static func get(_ urlString: String, userAgent: String? = nil,
                    okNote: String, unauthorizedNote: String? = nil) async -> ConnectionTest.Outcome {
        guard let url = URL(string: urlString) else { return .failure("Invalid URL.") }
        let start = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach \(url.host ?? urlString).")
        }
        switch http.statusCode {
        case 200: return .ok(ms(since: start))
        case 401, 403: return .failure(unauthorizedNote ?? "Unauthorized. Check the API key.")
        default: return .failure("HTTP \(http.statusCode).")
        }
    }

    static func postJSON(_ urlString: String, body: [String: Any],
                         bearer: String? = nil) async -> ConnectionTest.Outcome {
        guard let url = URL(string: urlString) else { return .failure("Invalid URL.") }
        let start = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach \(url.host ?? urlString).")
        }
        switch http.statusCode {
        case 200: return .ok(ms(since: start))
        case 401, 403: return .failure("Check the API key.")
        default: return .failure("HTTP \(http.statusCode).")
        }
    }
}
