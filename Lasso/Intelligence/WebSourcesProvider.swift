import Foundation
import CoreGraphics

/// Single switch for "nothing but the chosen model endpoint may be contacted" — the enterprise /
/// locked-down posture. Read everywhere auxiliary network would otherwise happen (web search,
/// favicons, page-title enrichment) so Lasso can run with zero incidental egress.
enum PrivacyMode {
    static var localOnly: Bool { UserDefaults.standard.bool(forKey: "privacy.localOnly") }
}

/// Free text-query web sources for the Identify pipeline: Wikipedia + DuckDuckGo (clean abstracts
/// and links) and Reddit's public search.json (community discussion), plus keyed Tavily/SerpApi.
/// Everything here is a plain in-process URLSession HTTP call — no WKWebView, no helper processes —
/// so it behaves like any other network request regardless of setup. These leave the Mac, so
/// they're gated by the "Web search" setting and suppressed entirely in local-only mode.
struct WebSourcesProvider {
    struct Hit: Identifiable, Codable {
        let id = UUID()
        let title: String
        let url: URL?
        let source: String   // "DuckDuckGo" / subreddit name
        var score: Double?   // semantic relevance (0–1), set by the ranker

        private enum CodingKeys: String, CodingKey { case title, url, source, score }
    }

    struct Result {
        var abstract: String?      // DDG abstract text for synthesis context
        var hits: [Hit] = []       // related links (DDG + Reddit) for display + synthesis
    }

    /// Managed search. Order of priority for *quality*: keyed APIs (Tavily primary, SerpApi reserve)
    /// over free sources — but spent carefully:
    ///   1. Cache-first (7-day TTL) — repeats cost zero quota.
    ///   2. Free baseline always (Wikipedia abstract + links, DuckDuckGo).
    ///   3. Tavily proactively when daily+monthly budget allows (its results lead the list).
    ///   4. SerpApi only as a reserve (Tavily empty / no Tavily budget), since its quota is tiny.
    /// Reddit (search.json) is fetched here too. Everything is embedding-ranked in IdentifyView.
    func lookup(_ query: String) async -> Result {
        // Defense in depth: local-only mode contacts nothing but the model endpoint.
        guard !PrivacyMode.localOnly else { return Result() }

        if let cached = SearchCache.get(query) {
            var result = Result(abstract: cached.abstract)
            result.hits = cached.hits
            return result
        }

        // Free baseline — always, no quota.
        async let wiki = wikipedia(query)
        async let instant = duckDuckGo(query)
        async let webResults = duckDuckGoWeb(query)
        async let redditResults = reddit(query)
        let (w, inst, web, red) = await (wiki, instant, webResults, redditResults)

        let abstract = w.abstract ?? inst.abstract     // prefer Wikipedia (stable)
        var hits = w.hits + web + red

        // Primary: Tavily (best results), budget-paced — its hits lead.
        if hasKey("tavily.apiKey"), SearchQuota.canUse("tavily") {
            let tav = await tavily(query)
            hits = tav + hits
            // Reserve: SerpApi only if Tavily returned nothing.
            if tav.isEmpty, hasKey("serpapi.apiKey"), SearchQuota.canUse("serpapi") {
                hits = await serpAPI(query) + hits
            }
        } else if hasKey("serpapi.apiKey"), SearchQuota.canUse("serpapi") {
            // No Tavily key/budget → fall back to the SerpApi reserve.
            hits = await serpAPI(query) + hits
        }

        SearchCache.set(query, abstract: abstract, hits: hits)
        var result = Result(abstract: abstract)
        result.hits = hits
        return result
    }

    private func hasKey(_ account: String) -> Bool {
        !(Keychain.getMigrating(account, legacyDefaultsKey: account) ?? "").isEmpty
    }

    // MARK: SerpApi (free 250/mo, needs an API key — real Google results)

    private func serpAPI(_ query: String) async -> [Hit] {
        let key = Keychain.getMigrating("serpapi.apiKey", legacyDefaultsKey: "serpapi.apiKey") ?? ""
        guard !key.isEmpty,
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://serpapi.com/search.json?engine=google&num=8&q=\(q)&api_key=\(k)")
        else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organic = json["organic_results"] as? [[String: Any]] else { return [] }
        SearchQuota.record("serpapi")
        return organic.prefix(6).compactMap { result -> Hit? in
            guard let title = result["title"] as? String, !title.isEmpty else { return nil }
            return Hit(title: title, url: (result["link"] as? String).flatMap { URL(string: $0) },
                       source: "Google")
        }
    }

    // MARK: Wikipedia (official, free, no key — the stable core)

    private func wikipedia(_ query: String) async -> (abstract: String?, hits: [Hit]) {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search"
                            + "&srsearch=\(q)&format=json&srlimit=3") else { return (nil, []) }
        var request = URLRequest(url: url)
        request.setValue("Lasso/0.1 (on-device identify)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let results = queryObj["search"] as? [[String: Any]] else { return (nil, []) }

        let titles = results.compactMap { $0["title"] as? String }
        let hits = titles.compactMap { title -> Hit? in
            wikiURL(title).map { Hit(title: title, url: $0, source: "Wikipedia") }
        }
        var abstract: String?
        if let top = titles.first { abstract = await wikiSummary(top) }
        return (abstract, hits)
    }

    private func wikiSummary(_ title: String) async -> String? {
        guard let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Lasso/0.1 (on-device identify)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extract = json["extract"] as? String, !extract.isEmpty else { return nil }
        return extract
    }

    private func wikiURL(_ title: String) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return URL(string: "https://en.wikipedia.org/wiki/\(path)")
    }

    // MARK: Tavily (free 1,000/mo, needs an API key — stable real web search)

    private func tavily(_ query: String) async -> [Hit] {
        let key = Keychain.getMigrating("tavily.apiKey", legacyDefaultsKey: "tavily.apiKey") ?? ""
        guard !key.isEmpty, let url = URL(string: "https://api.tavily.com/search") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")   // newer Tavily
        request.timeoutInterval = 8
        request.httpBody = try? JSONEncoder().encode(
            TavilyRequest(api_key: key, query: query, max_results: 6, search_depth: "basic"))

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TavilyResponse.self, from: data) else {
            return []
        }
        SearchQuota.record("tavily")
        return decoded.results.prefix(6).compactMap { result in
            guard !result.title.isEmpty else { return nil }
            return Hit(title: result.title, url: URL(string: result.url), source: "Tavily")
        }
    }

    // MARK: DuckDuckGo Instant Answer (JSON)

    private func duckDuckGo(_ query: String) async -> (abstract: String?, hits: [Hit]) {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(q)&format=json&no_html=1&skip_disambig=1")
        else { return (nil, []) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, []) }

        let abstractText = (json["AbstractText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var hits: [Hit] = []
        if let related = json["RelatedTopics"] as? [[String: Any]] {
            for topic in related.prefix(5) {
                if let text = topic["Text"] as? String,
                   let urlString = topic["FirstURL"] as? String, let u = URL(string: urlString) {
                    hits.append(Hit(title: text, url: u, source: "DuckDuckGo"))
                }
            }
        }
        return (abstractText, hits)
    }

    // MARK: DuckDuckGo web results (HTML — real links for any query)

    private func duckDuckGoWeb(_ query: String) async -> [Hit] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }

        let pattern = "class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)<"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> Hit? in
                let href = ns.substring(with: match.range(at: 1))
                let title = decodeEntities(ns.substring(with: match.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let url = decodeUddg(href)
                if let host = url?.host, DomainNoise.isNoise(host) { return nil }
                return Hit(title: title, url: url, source: "DuckDuckGo")
            }
            .prefix(6)
            .map { $0 }
    }

    // MARK: Reddit (public search.json — community discussion, no key)

    /// Query Reddit's public JSON search over URLSession (replaces the old hidden WKWebView scraper).
    /// Best-effort: Reddit rate-limits unauthenticated search, so this returns nothing on a 429/403
    /// rather than failing the pipeline. A descriptive User-Agent is required by Reddit's API rules.
    private func reddit(_ query: String) async -> [Hit] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.reddit.com/search.json?q=\(q)"
                            + "&limit=8&sort=relevance&t=year&include_over_18=off") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("macOS:com.cjcarito.Lasso:v1 (by /u/lasso-app)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let children = dataObj["children"] as? [[String: Any]] else { return [] }

        return children.prefix(8).compactMap { child -> Hit? in
            guard let post = child["data"] as? [String: Any],
                  let title = post["title"] as? String, !title.isEmpty else { return nil }
            let permalink = (post["permalink"] as? String).map { "https://www.reddit.com\($0)" }
            let sub = (post["subreddit_name_prefixed"] as? String) ?? "reddit"
            return Hit(title: title, url: permalink.flatMap { URL(string: $0) }, source: sub)
        }
    }

    /// DDG result links are `//duckduckgo.com/l/?uddg=<encoded real url>&rut=…` — unwrap them.
    private func decodeUddg(_ href: String) -> URL? {
        let absolute = href.hasPrefix("//") ? "https:\(href)" : href
        if let comps = URLComponents(string: absolute),
           let real = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let url = URL(string: real) {
            return url
        }
        return URL(string: absolute)
    }

    private func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private struct TavilyRequest: Encodable {
    let api_key: String
    let query: String
    let max_results: Int
    let search_depth: String
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable { let title: String; let url: String; let content: String? }
    let results: [Result]
}

// MARK: - Identify source registry (the "bring your own tool" surface)

/// Evidence one source contributes to Identify. Sources only fill what they can; the pipeline fuses
/// the lot. `bestGuess` is the strongest signal (a named identity from reverse-image search).
struct Evidence {
    var bestGuess: String?                          // e.g. "adrien brody the pianist"
    var entities: [String] = []                     // recognized web entities, ranked
    var abstract: String?                           // encyclopedic context
    var hits: [WebSourcesProvider.Hit] = []         // related links
    var error: String?                              // surfaced when a configured source fails

    mutating func merge(_ other: Evidence) {
        if (bestGuess?.isEmpty ?? true), let b = other.bestGuess, !b.isEmpty { bestGuess = b }
        entities += other.entities
        if abstract == nil { abstract = other.abstract }
        hits += other.hits
        if error == nil { error = other.error }
    }
}

/// Whether a source runs before the text query is finalized (image-based, can refine the query) or
/// after (it consumes the query).
enum SourceKind { case visual, textual }

/// A pluggable evidence source for Identify. Each is independently toggleable and fault-isolated:
/// the pipeline wraps every `gather` so a source that's off, unconfigured, or failing simply
/// contributes nothing and can never break Identify. This is where "bring your own tool" lives —
/// new capabilities are added by implementing this and registering them in `IdentifySources.all`.
protocol IdentifySource: Sendable {
    var id: String { get }                          // stable key (used in Settings + defaults)
    var title: String { get }                       // display name
    var detail: String { get }                      // one-line description for Settings
    var kind: SourceKind { get }
    var leavesDevice: Bool { get }                  // makes off-device network calls
    var requiresKey: Bool { get }
    var enabledKey: String { get }                  // UserDefaults key backing the on/off toggle
    var defaultEnabled: Bool { get }
    func isConfigured() -> Bool                      // key present, etc.
    func gather(image: CGImage, query: String, ocrText: String?) async -> Evidence
}

extension IdentifySource {
    var requiresKey: Bool { false }
    func isConfigured() -> Bool { true }
}

/// The catalog of Identify sources + their enable state. Add a source here to "install" it.
enum IdentifySources {
    /// Display/run order. Built-ins first, then bring-your-own-key tools.
    static func all() -> [IdentifySource] {
        [WebSearchSource(), GoogleVisionSource()]
    }

    static func isEnabled(_ source: IdentifySource) -> Bool {
        UserDefaults.standard.object(forKey: source.enabledKey) as? Bool ?? source.defaultEnabled
    }

    /// Sources that should actually run now: enabled + configured, and — in local-only mode — only
    /// those that never leave the Mac (today that's none, so Identify stays fully local).
    static func active() -> [IdentifySource] {
        all().filter { source in
            guard isEnabled(source), !source.requiresKey || source.isConfigured() else { return false }
            return !PrivacyMode.localOnly || !source.leavesDevice
        }
    }
}

/// Built-in source: Wikipedia + DuckDuckGo + Reddit (and optional Tavily/SerpApi keys), all over
/// plain URLSession. Backed by the existing `imageSearch.enabled` toggle for continuity.
struct WebSearchSource: IdentifySource {
    let id = "web"
    let title = "Web search"
    let detail = "Wikipedia, DuckDuckGo and Reddit for context. Optional Tavily / SerpApi keys add stronger results."
    let kind = SourceKind.textual
    let leavesDevice = true
    let enabledKey = "imageSearch.enabled"
    let defaultEnabled = false

    func gather(image: CGImage, query: String, ocrText: String?) async -> Evidence {
        guard !query.isEmpty else { return Evidence() }
        let result = await WebSourcesProvider().lookup(query)
        return Evidence(abstract: result.abstract, hits: result.hits)
    }
}

/// Bring-your-own-key source: Google Cloud Vision "Web Detection". POSTs the image bytes to Google
/// with the user's own API key and returns a best-guess identity label, recognized entities, and
/// pages that carry the same image — the reverse-image signal, with no embedded browser. Off by
/// default; disabled in local-only mode.
struct GoogleVisionSource: IdentifySource {
    let id = "googleVision"
    let title = "Reverse image (Google Vision)"
    let detail = "Identifies the subject by matching the image across the web. Uses your Google Cloud Vision API key (free tier ~1,000/mo)."
    let kind = SourceKind.visual
    let leavesDevice = true
    let requiresKey = true
    let enabledKey = "identify.source.googleVision.enabled"
    let defaultEnabled = false

    static let keyAccount = "googleVision.apiKey"

    func isConfigured() -> Bool {
        !(Keychain.getMigrating(Self.keyAccount, legacyDefaultsKey: Self.keyAccount) ?? "").isEmpty
    }

    func gather(image: CGImage, query: String, ocrText: String?) async -> Evidence {
        guard let key = Keychain.get(Self.keyAccount), !key.isEmpty,
              let base64 = ImageEncoder.jpegBase64(image, maxEdge: 1024),
              let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(encodedKey)")
        else { return Evidence() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "requests": [[
                "image": ["content": base64],
                "features": [["type": "WEB_DETECTION", "maxResults": 10]],
            ]],
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return Evidence(error: "Google Vision: couldn't reach the API (network).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            // Google returns { "error": { "message": "…" } } — surface its own words.
            let apiMessage = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? "HTTP \(status)"
            Log.intelligence.error("Google Vision failed (\(status, privacy: .public)): \(apiMessage, privacy: .public)")
            return Evidence(error: "Google Vision: \(apiMessage)")
        }
        guard let responses = json?["responses"] as? [[String: Any]] else { return Evidence() }
        // A per-image error can ride inside a 200 response too.
        if let inner = (responses.first?["error"] as? [String: Any])?["message"] as? String {
            return Evidence(error: "Google Vision: \(inner)")
        }
        guard let web = responses.first?["webDetection"] as? [String: Any] else {
            return Evidence()   // succeeded, just no web matches for this image
        }

        // A best-guess only counts as an *identification* if it's specific. Web Detection falls back
        // to generic content labels ("Human", "Photograph") when the exact image isn't indexed —
        // those must NOT drive the query or be presented as an answer, or Identify "confidently"
        // describes the generic category instead of admitting it couldn't identify the subject.
        let rawLabel = (web["bestGuessLabels"] as? [[String: Any]])?
            .first?["label"] as? String ?? ""
        let identified = !rawLabel.isEmpty && !Self.isGeneric(rawLabel)

        var evidence = Evidence()
        if identified {
            evidence.bestGuess = rawLabel
            if let entities = web["webEntities"] as? [[String: Any]] {
                evidence.entities = entities
                    .compactMap { $0["description"] as? String }
                    .filter { !$0.isEmpty && !Self.isGeneric($0) }
                    .prefix(6).map { $0 }
            }
        }
        if let pages = web["pagesWithMatchingImages"] as? [[String: Any]] {
            evidence.hits = pages.prefix(8).compactMap { page -> WebSourcesProvider.Hit? in
                guard let urlString = page["url"] as? String, let pageURL = URL(string: urlString)
                else { return nil }
                if let host = pageURL.host, DomainNoise.isNoise(host) { return nil }
                let title = (page["pageTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? pageURL.host ?? urlString
                // When unidentified, drop generic "Human – Wikipedia"-style pages too.
                if !identified, Self.isGeneric(title) { return nil }
                return WebSourcesProvider.Hit(title: title, url: pageURL,
                                              source: pageURL.host ?? "web")
            }
        }
        return evidence
    }

    /// Non-identifying content labels Google returns when it can't match the exact image. Treated as
    /// "no identification" so they don't pollute the query or the answer.
    private static let genericTerms: Set<String> = [
        "human", "person", "people", "man", "woman", "boy", "girl", "child", "adult",
        "face", "head", "neck", "chin", "forehead", "jaw", "cheek", "nose", "eyebrow",
        "hair", "hairstyle", "facial hair", "beard", "moustache", "mustache", "skin",
        "photograph", "photography", "portrait", "portrait photography", "photo", "picture",
        "image", "selfie", "snapshot", "smile", "glasses", "eyewear",
    ]

    static func isGeneric(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if genericTerms.contains(t) { return true }
        // "Human", "Human - Wikipedia", "Human | NOVA", "Modern humans …" → generic.
        let head = t.split(whereSeparator: { " -|:–—".contains($0) }).first.map(String.init) ?? t
        return genericTerms.contains(head)
    }
}

