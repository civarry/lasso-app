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

    /// Run DuckDuckGo (instant answer + web results) + Reddit in parallel for `query`.
    func lookup(_ query: String) async -> Result {
        async let instant = duckDuckGo(query)
        async let webResults = duckDuckGoWeb(query)
        async let reddit = reddit(query)
        let (inst, web, red) = await (instant, webResults, reddit)
        var result = Result(abstract: inst.abstract)
        // Real web result links first (work for any query), then Reddit.
        result.hits = web + red
        return result
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

    // MARK: Reddit search.json

    private func reddit(_ query: String) async -> [Hit] {
        // Requires a Reddit client ID (app-only OAuth). Without it, Reddit is simply skipped.
        let clientID = UserDefaults.standard.string(forKey: "reddit.clientID") ?? ""
        guard !clientID.isEmpty,
              let token = await RedditAuth.shared.token(clientID: clientID),
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://oauth.reddit.com/search?q=\(q)&limit=8&sort=relevance&t=year&raw_json=1")
        else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(RedditAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return [] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listing = json["data"] as? [String: Any],
              let children = listing["children"] as? [[String: Any]] else {
            Log.intelligence.notice("Reddit oauth search HTTP \(status, privacy: .public)")
            return []
        }
        return children.prefix(6).compactMap { child -> Hit? in
            guard let data = child["data"] as? [String: Any],
                  let title = data["title"] as? String, !title.isEmpty,
                  (data["over_18"] as? Bool) != true else { return nil }
            let permalink = data["permalink"] as? String ?? ""
            let sub = data["subreddit"] as? String ?? "reddit"
            return Hit(title: title, url: URL(string: "https://www.reddit.com\(permalink)"),
                       source: "r/\(sub)")
        }
    }
}
