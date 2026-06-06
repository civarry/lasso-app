import Foundation

/// Free text-query web sources for the Identify pipeline: DuckDuckGo Instant Answer (a clean
/// Wikipedia-style abstract) and Reddit search.json (community discussion). No API keys. These
/// leave the Mac, so they're gated by the "Web lookup" setting.
struct WebSourcesProvider {
    struct Hit: Identifiable {
        let id = UUID()
        let title: String
        let url: URL?
        let source: String   // "DuckDuckGo" / subreddit name
        var score: Double?   // semantic relevance (0–1), set by the ranker
    }

    struct Result {
        var abstract: String?      // DDG abstract text for synthesis context
        var hits: [Hit] = []       // related links (DDG + Reddit) for display + synthesis
    }

    /// Stable-first web sources: Wikipedia (official, no key) for the abstract + links, Tavily (free
    /// key) for real web results, then DuckDuckGo (best-effort). Reddit is handled separately via a
    /// hidden WebView (RedditWorker). All ranked by embedding similarity in IdentifyView.
    static let tavilyMonthlyCap = 950   // free tier 1,000 — leave a safety margin
    static let serpMonthlyCap = 95      // free tier 100

    /// Managed cascade: always use the free, unlimited tier (Wikipedia + DuckDuckGo); only escalate
    /// to the limited keyed APIs (Tavily, then SerpApi) when free results are thin and quota remains.
    /// Reddit is added separately (WebView) in IdentifyView.
    func lookup(_ query: String) async -> Result {
        async let wiki = wikipedia(query)
        async let instant = duckDuckGo(query)
        async let webResults = duckDuckGoWeb(query)
        let (w, inst, web) = await (wiki, instant, webResults)

        let abstract = w.abstract ?? inst.abstract     // prefer Wikipedia (stable)
        var hits = w.hits + web

        // Enough from free sources? Then don't spend keyed quota.
        let freeEnough = abstract != nil || hits.count >= 4
        if !freeEnough {
            if hasKey("tavily.apiKey"), SearchQuota.canUse("tavily", cap: Self.tavilyMonthlyCap) {
                hits += await tavily(query)
            }
            if hits.count < 4, hasKey("serpapi.apiKey"),
               SearchQuota.canUse("serpapi", cap: Self.serpMonthlyCap) {
                hits += await serpAPI(query)
            }
        }

        var result = Result(abstract: abstract)
        result.hits = hits
        return result
    }

    private func hasKey(_ key: String) -> Bool {
        !(UserDefaults.standard.string(forKey: key) ?? "").isEmpty
    }

    // MARK: SerpApi (free 100/mo, needs an API key — real Google results)

    private func serpAPI(_ query: String) async -> [Hit] {
        let key = UserDefaults.standard.string(forKey: "serpapi.apiKey") ?? ""
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
        let key = UserDefaults.standard.string(forKey: "tavily.apiKey") ?? ""
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
                if let host = url?.host?.lowercased(), Self.isNoise(host) { return nil }
                return Hit(title: title, url: url, source: "DuckDuckGo")
            }
            .prefix(6)
            .map { $0 }
    }

    /// Drop shopping / stock / wallpaper / social hosts so "Related" shows articles, not noise.
    private static func isNoise(_ host: String) -> Bool {
        let blocked = ["amazon.", "etsy.", "aliexpress.", "ebay.", "pinterest.", "shutterstock.",
                       "istockphoto.", "gettyimages.", "alamy.", "dreamstime.", "walmart.", "temu.",
                       "alibaba.", "redbubble.", "lazada.", "shopee.", "wallpaper", "facebook.",
                       "instagram.", "tiktok.", "youtube."]
        return blocked.contains { host.contains($0) }
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

