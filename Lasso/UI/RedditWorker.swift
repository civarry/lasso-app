import SwiftUI
import WebKit

/// Hidden WebView that loads old.reddit.com/search (server-rendered, browser context clears
/// Reddit's bot block) and scrapes the results — the native equivalent of a browser/proxy fetch.
/// Best-effort: returns nothing if Reddit changes markup or shows an interstitial.
struct RedditWorker: NSViewRepresentable {
    let query: String
    let onHits: ([WebSourcesProvider.Hit]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHits: onHits) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string:
            "https://old.reddit.com/search?q=\(q)&sort=relevance&t=year&include_over_18=off") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onHits: ([WebSourcesProvider.Hit]) -> Void
        private var delivered = false
        private var polls = 0

        init(onHits: @escaping ([WebSourcesProvider.Hit]) -> Void) { self.onHits = onHits }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scrape(webView)
        }

        private func scrape(_ webView: WKWebView) {
            guard !delivered, polls < 5 else { return }
            polls += 1
            webView.evaluateJavaScript(Self.scrapeScript) { [weak self, weak webView] result, _ in
                guard let self else { return }
                if let json = result as? String, let hits = Self.parse(json), !hits.isEmpty {
                    delivered = true
                    onHits(hits)
                    return
                }
                if let webView {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.scrape(webView) }
                }
            }
        }

        private static func parse(_ json: String) -> [WebSourcesProvider.Hit]? {
            guard let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
            else { return nil }
            return array.compactMap { dict in
                guard let title = dict["title"], !title.isEmpty else { return nil }
                return WebSourcesProvider.Hit(title: title,
                                              url: dict["url"].flatMap { URL(string: $0) },
                                              source: dict["source"] ?? "reddit")
            }
        }

        private static let scrapeScript = """
        (function () {
          var out = [];
          var titles = document.querySelectorAll('a.search-title');
          for (var i = 0; i < titles.length && out.length < 8; i++) {
            var a = titles[i];
            var title = (a.textContent || '').trim();
            var href = a.href;
            if (!title || !href) continue;
            var result = a.closest('.search-result') || a.parentElement;
            var subEl = result ? result.querySelector('.search-subreddit-link') : null;
            var sub = subEl ? (subEl.textContent || '').trim() : 'reddit';
            out.push({ title: title, url: href, source: sub });
          }
          return JSON.stringify(out);
        })();
        """
    }
}
