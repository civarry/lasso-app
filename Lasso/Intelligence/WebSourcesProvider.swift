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
        var snippet: String? // short extract of the page text, for grounding (when available)

        private enum CodingKeys: String, CodingKey { case title, url, source, score, snippet }
    }

    struct Result {
        var abstract: String?      // DDG abstract text for synthesis context
        /// What the abstract is *about* (the Wikipedia article title, or the engine name). Without this
        /// the abstract reads as an answer to the question rather than as a summary of whatever page
        /// happened to rank first, which is how "Mars Hill University" became a Mars presidency.
        var abstractSource: String?
        var hits: [Hit] = []       // related links (DDG + Reddit) for display + synthesis
    }

    /// Managed search. Order of priority for *quality*: keyed APIs (Tavily primary, SerpApi reserve)
    /// over free sources — but spent carefully:
    ///   1. Cache-first (7-day TTL) — repeats cost zero quota.
    ///   2. Free baseline always (Wikipedia abstract + links, DuckDuckGo).
    ///   3. Tavily proactively when daily+monthly budget allows (its results lead the list).
    ///   4. SerpApi only as a reserve (Tavily empty / no Tavily budget), since its quota is tiny.
    /// Reddit (search.json) is fetched here too. Everything is embedding-ranked in IdentifyView.
    /// Time one source. Purely observational: the work is unchanged and still runs concurrently with
    /// its siblings, so this reports the real wall clock each connector contributes to a turn.
    private static func timed<T>(_ name: String, _ work: () async -> T) async -> T {
        let t0 = Date()
        let out = await work()
        Log.chat.notice("web source · \(name, privacy: .public) \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
        return out
    }

    func lookup(_ query: String) async -> Result {
        // Defense in depth: local-only mode contacts nothing but the model endpoint.
        guard !PrivacyMode.localOnly else { return Result() }

        let freeOn = Connectors.webSearch.isActive()
        let tavilyOn = Connectors.tavily.isActive()
        let serpOn = Connectors.serpApi.isActive()

        // Cache per active config — otherwise enabling/disabling a source would replay stale hits.
        let cacheKey = "w\(freeOn ? 1 : 0)t\(tavilyOn ? 1 : 0)s\(serpOn ? 1 : 0)|\(query)"
        if let cached = SearchCache.get(cacheKey) {
            // Logged so a cached turn is never mistaken for a fast network (it was: a repeated query
            // returned in 264ms and a fresh one took 3.4s on the same connectors).
            Log.chat.notice("web source · CACHE HIT (\(cached.hits.count, privacy: .public) hits)")
            var result = Result(abstract: cached.abstract, abstractSource: cached.abstractSource)
            result.hits = cached.hits
            return result
        }

        var abstract: String?
        var abstractSource: String?
        var hits: [Hit] = []
        // Phase clock. The per-source timings above cover only the concurrent free block; a real run
        // showed max(source)=1255ms against fetch=3048ms, so ~1.8s was being spent somewhere these
        // numbers could not see. Everything below is on the critical path and now says so.
        let tStart = Date()
        func since(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
        var freeMs = 0, dedupMs = 0, tavilyMs = 0, serpMs = 0

        // Tavily reads none of the free results — its hits are simply merged in front of them — so it
        // has no reason to wait for them. Measured on a real turn: the whole concurrent free block
        // cost 1136ms and Tavily then added 2605ms of pure serial time after it. Started here, that
        // cost overlaps instead of stacking. SerpApi genuinely depends on the deduped hit count
        // (it only tops up a thin set), so that one stays where it is.
        var tavilyTask: Task<[Hit], Never>?
        if tavilyOn, SearchQuota.canUse("tavily") {
            tavilyTask = Task { await tavily(query) }
        }

        // Free baseline (Wikipedia / DuckDuckGo / Reddit) — only when the Web search connector is on.
        if freeOn {
            // Timed individually. These four run concurrently, so the fetch costs whatever the
            // *slowest* one costs, and an aggregate number can't tell you which to fix.
            async let wiki = Self.timed("wikipedia") { await wikipedia(query) }
            async let instant = Self.timed("ddg-instant") { await duckDuckGo(query) }
            async let webResults = Self.timed("ddg-web") { await duckDuckGoWeb(query) }
            async let redditResults = Self.timed("reddit") { await reddit(query) }
            let (w, inst, web, red) = await (wiki, instant, webResults, redditResults)
            abstract = w.abstract ?? inst.abstract     // prefer Wikipedia (stable)
            // Only Wikipedia has a *subject* distinct from the query (the article that ranked first),
            // which is the thing the abstract gate needs to check. DuckDuckGo's instant answer is
            // derived from the query itself, so it has no separate subject and stays nil.
            abstractSource = w.title
            hits = w.hits + web + red
            freeMs = since(tStart)
        }

        let tDedup = Date()
        hits = Self.deduped(hits)
        dedupMs = since(tDedup)

        // Tavily: primary paid source (best results + snippets), budget-paced — its hits lead.
        // `tavilyMs` is now the *remaining* wait after the overlap, which is the number that matters:
        // it is what Tavily still adds to the turn, not what it costs in isolation.
        if let tavilyTask {
            let t = Date()
            hits = Self.deduped(await tavilyTask.value + hits)
            tavilyMs = since(t)
        }
        // SerpApi: a top-up, not a strict reserve — fill only when the deduped set is thin (so a
        // configured key actually helps), still gated by its small monthly quota.
        if serpOn, hits.count < Self.serpTopUpThreshold, SearchQuota.canUse("serpapi") {
            let t = Date()
            let serp = await serpAPI(query)
            hits = Self.deduped(hits + serp)
            serpMs = since(t)
        }

        Log.chat.notice("lookup · free=\(freeMs, privacy: .public)ms dedup=\(dedupMs, privacy: .public)ms tavily=\(tavilyMs, privacy: .public)ms serp=\(serpMs, privacy: .public)ms total=\(since(tStart), privacy: .public)ms")
        SearchCache.set(cacheKey, abstract: abstract, abstractSource: abstractSource, hits: hits)
        var result = Result(abstract: abstract, abstractSource: abstractSource)
        result.hits = hits
        return result
    }

    /// Below this many distinct hits, pull SerpApi to top up (rather than only when Tavily is empty).
    private static let serpTopUpThreshold = 5

    /// Collapse duplicate results across sources by normalized URL (host+path, case/scheme/trailing-slash
    /// and query/fragment insensitive), falling back to normalized title when there's no URL. Keeps the
    /// FIRST occurrence — sources are concatenated highest-authority-first, so first-seen wins — and
    /// adopts a snippet from a later duplicate if the kept hit lacks one (only Tavily carries snippets).
    static func deduped(_ hits: [Hit]) -> [Hit] {
        var seen: [String: Int] = [:]     // key → index in out
        var out: [Hit] = []
        for hit in hits {
            let key = dedupKey(hit)
            if let idx = seen[key] {
                if (out[idx].snippet?.isEmpty ?? true), let s = hit.snippet, !s.isEmpty {
                    out[idx].snippet = s
                }
            } else {
                seen[key] = out.count
                out.append(hit)
            }
        }
        return out
    }

    private static func dedupKey(_ hit: Hit) -> String {
        if let url = hit.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let host = comps.host {
            let path = comps.path.hasSuffix("/") && comps.path.count > 1
                ? String(comps.path.dropLast()) : comps.path
            return (host + path).lowercased()
        }
        return hit.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func wikipedia(_ query: String) async -> (abstract: String?, title: String?, hits: [Hit]) {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search"
                            + "&srsearch=\(q)&format=json&srlimit=3") else { return (nil, nil, []) }
        var request = URLRequest(url: url)
        request.setValue("Lasso/0.1 (on-device identify)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let results = queryObj["search"] as? [[String: Any]] else { return (nil, nil, []) }

        let titles = results.compactMap { $0["title"] as? String }
        let hits = titles.compactMap { title -> Hit? in
            wikiURL(title).map { Hit(title: title, url: $0, source: "Wikipedia") }
        }
        var abstract: String?
        if let top = titles.first { abstract = await wikiSummary(top) }
        return (abstract, abstract == nil ? nil : titles.first, hits)
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
            return Hit(title: result.title, url: URL(string: result.url), source: "Tavily",
                       snippet: result.content)
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
    var abstractSource: String?                     // the page/engine the abstract came from
    /// True when no source actually cleared the relevance bar and the closest ones were kept anyway.
    /// Surfaced to the model rather than used to delete evidence: see `relevanceIsWeak`.
    var relevanceIsWeak = false
    var hits: [WebSourcesProvider.Hit] = []         // related links
    var error: String?                              // surfaced when a configured source fails

    mutating func merge(_ other: Evidence) {
        if (bestGuess?.isEmpty ?? true), let b = other.bestGuess, !b.isEmpty { bestGuess = b }
        entities += other.entities
        if abstract == nil { abstract = other.abstract; abstractSource = other.abstractSource }
        hits += other.hits
        if error == nil { error = other.error }
    }

    var isEmpty: Bool {
        (bestGuess?.isEmpty ?? true) && entities.isEmpty
            && (abstract?.isEmpty ?? true) && hits.isEmpty
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
        [WebSearchSource()]
    }

    static func isEnabled(_ source: IdentifySource) -> Bool {
        UserDefaults.standard.object(forKey: source.enabledKey) as? Bool ?? source.defaultEnabled
    }

    /// Sources that should actually run now: enabled + configured, and — in local-only mode — only
    /// those that never leave the Mac (today that's none, so Identify stays fully local).
    static func active() -> [IdentifySource] {
        all().filter { source in
            // The "web" source is the hub for three independent text connectors (Web search, Tavily,
            // SerpApi) that layer into one lookup — run it if ANY of them is active, so Tavily/SerpApi
            // work on their own without Web search also being on. (isActive() already respects
            // local-only.)
            if source.id == "web" {
                return Connectors.webSearch.isActive()
                    || Connectors.tavily.isActive()
                    || Connectors.serpApi.isActive()
            }
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

