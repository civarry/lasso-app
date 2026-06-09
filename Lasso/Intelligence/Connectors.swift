import Foundation
import CoreGraphics

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
    static let all: [Connector] = [webSearch, tavily, serpApi, googleVision]

    static func by(id: String) -> Connector? { all.first { $0.id == id } }

    // MARK: Built-in: web search (keyless)

    static let webSearch = Connector(
        id: "webSearch",
        name: "Web search",
        icon: "globe",
        iconDomain: "duckduckgo.com",
        usesImage: false,
        summary: "Text web search (Wikipedia, DuckDuckGo, Reddit) for context — no account needed.",
        leavesDevice: true,
        enabledKey: "imageSearch.enabled",
        defaultEnabled: false,
        keyAccount: nil,
        guide: SetupGuide([
            .init("Just turn it on — it uses free public sources over plain HTTP (no embedded browser)."),
            .init("Optional: connect Tavily or SerpApi below for stronger, ranked web results."),
        ], note: "Leaves your Mac. Paused automatically in local-only mode."),
        test: { _ in
            await ConnectorTests.get(
                "https://en.wikipedia.org/w/api.php?action=query&meta=siteinfo&format=json",
                userAgent: "Lasso/0.1 (connector test)",
                okNote: "Reachable")
        })

    // MARK: Tavily (BYO key)

    static let tavily = Connector(
        id: "tavily",
        name: "Tavily",
        icon: "magnifyingglass.circle",
        iconDomain: "tavily.com",
        usesImage: false,
        summary: "Text web search tuned for AI — clean, ranked results from a search query (not the image).",
        leavesDevice: true,
        enabledKey: "connector.tavily.enabled",
        defaultEnabled: false,
        keyAccount: "tavily.apiKey",
        guide: SetupGuide([
            .init("Create a free Tavily account.", link: "https://app.tavily.com/", linkLabel: "Open Tavily"),
            .init("Open the dashboard — your API key is shown on the home page."),
            .init("Copy the key (starts with “tvly-”) and paste it below."),
        ], note: "Free tier ≈ 1,000 searches/month. Leaves your Mac."),
        test: { key in
            guard !key.isEmpty else { return .failure("Enter an API key.") }
            return await ConnectorTests.postJSON(
                "https://api.tavily.com/search",
                body: ["api_key": key, "query": "lasso connector test", "max_results": 1],
                bearer: key)
        })

    // MARK: SerpApi (BYO key)

    static let serpApi = Connector(
        id: "serpApi",
        name: "SerpApi",
        icon: "magnifyingglass.circle.fill",
        iconDomain: "serpapi.com",
        usesImage: false,
        summary: "Real Google text results via SerpApi — a reserve source when Tavily is empty.",
        leavesDevice: true,
        enabledKey: "connector.serpapi.enabled",
        defaultEnabled: false,
        keyAccount: "serpapi.apiKey",
        guide: SetupGuide([
            .init("Create a free SerpApi account.", link: "https://serpapi.com/users/sign_up", linkLabel: "Open SerpApi"),
            .init("Go to your dashboard → API Key.", link: "https://serpapi.com/manage-api-key", linkLabel: "API Key page"),
            .init("Copy the private API key and paste it below."),
        ], note: "Free tier ≈ 250 searches/month. Leaves your Mac."),
        test: { key in
            guard !key.isEmpty else { return .failure("Enter an API key.") }
            guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return .failure("Invalid API key.")
            }
            return await ConnectorTests.get(
                "https://serpapi.com/account.json?api_key=\(encoded)",
                okNote: "Account reachable",
                unauthorizedNote: "Check the API key.")
        })

    // MARK: Google Vision — reverse image (BYO key)

    static let googleVision = Connector(
        id: "googleVision",
        name: "Reverse image (Google Vision)",
        icon: "photo.on.rectangle.angled",
        iconDomain: "cloud.google.com",
        usesImage: true,
        summary: "Analyses the picture itself — matches the image across the web — best for products, "
            + "landmarks, logos, artwork and memes.",
        leavesDevice: true,
        enabledKey: "identify.source.googleVision.enabled",
        defaultEnabled: false,
        keyAccount: "googleVision.apiKey",
        guide: SetupGuide([
            .init("Open the Google Cloud Console and pick (or create) a project.",
                  link: "https://console.cloud.google.com/", linkLabel: "Open Console"),
            .init("Enable the Cloud Vision API for that project.",
                  link: "https://console.cloud.google.com/apis/library/vision.googleapis.com",
                  linkLabel: "Enable Vision API"),
            .init("Link a billing account (required even for the free tier).",
                  link: "https://console.cloud.google.com/billing", linkLabel: "Billing"),
            .init("Create an API key, then restrict it to the Cloud Vision API.",
                  link: "https://console.cloud.google.com/apis/credentials", linkLabel: "Credentials"),
            .init("Paste the key (starts with “AIza”) below."),
        ], note: "Free tier ≈ 1,000 Web Detection calls/month, then ~$3.50/1,000. Leaves your Mac."),
        test: { key in
            guard !key.isEmpty else { return .failure("Enter an API key.") }
            return await ConnectorTests.googleVision(key: key)
        })
}

// MARK: - Test helpers (lightweight URLSession probes; reused by the catalog's `test` closures)

enum ConnectorTests {
    /// A small real JPEG (16×16 grey), generated at runtime — a hard-coded 1×1 pixel gets rejected by
    /// Vision as "Bad image data", so we make a genuine image the decoder accepts.
    private static func probeImageBase64() -> String? {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return ImageEncoder.jpegBase64(image, maxEdge: side, quality: 0.8)
    }

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
        case 401, 403: return .failure(unauthorizedNote ?? "Unauthorized — check the API key.")
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

    /// Runs a real Web Detection on a 1×1 image so the test surfaces Google's own error message
    /// (the billing/permission diagnostic). Costs ~1 unit; only ever called from a manual Test tap.
    static func googleVision(key: String) async -> ConnectionTest.Outcome {
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(encoded)")
        else { return .failure("Invalid API key.") }
        guard let probe = probeImageBase64() else { return .failure("Couldn't build a test image.") }
        let start = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "requests": [["image": ["content": probe],
                          "features": [["type": "WEB_DETECTION", "maxResults": 1]]]],
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach Google Vision.")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if http.statusCode == 200,
           let inner = ((json?["responses"] as? [[String: Any]])?.first?["error"] as? [String: Any])?["message"] as? String {
            return .failure(inner)   // a per-image error can ride inside a 200
        }
        guard http.statusCode == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            return .failure(message)
        }
        return .ok(ms(since: start))
    }
}
