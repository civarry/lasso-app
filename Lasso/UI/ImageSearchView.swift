import SwiftUI
import WebKit
import AppKit

/// One reverse-image match, parsed from TinEye's results JSON.
struct ImageMatch: Identifiable, Codable {
    let id = UUID()
    let domain: String
    var title: String?      // enriched with the page <title> after the fact
    let pageURL: URL?
    let thumbURL: URL?
    let date: String?

    private enum CodingKeys: String, CodingKey { case domain, title, pageURL, thumbURL, date }
}

struct MatchRow: View {
    let match: ImageMatch
    let onOpen: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = match.pageURL { onOpen(url) }
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: match.thumbURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title?.isEmpty == false ? match.title! : match.domain)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(match.domain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let date = match.date {
                        Text(date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.white.opacity(hovering ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Hidden worker webview

struct TinEyeWorker: NSViewRepresentable {
    let image: CGImage
    let onMatches: ([ImageMatch]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(base64: Self.base64JPEG(image), onMatches: onMatches)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "lasso")
        controller.addUserScript(WKUserScript(source: Self.interceptorJS,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        WebScraper.loadBlockingMedia(webView) {
            webView.load(URLRequest(url: URL(string: "https://tineye.com/")!))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private static func base64JPEG(_ image: CGImage, maxEdge: Int = 1600, quality: CGFloat = 0.85) -> String {
        let scaled = image.downscaled(maxEdge: maxEdge)
        let rep = NSBitmapImageRep(cgImage: scaled)
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? Data()
        return data.base64EncodedString()
    }

    /// Hook fetch + XHR to forward TinEye's results JSON to native (stable across DOM changes).
    private static let interceptorJS = """
    (function () {
      function send(text) {
        try { window.webkit.messageHandlers.lasso.postMessage('json:' + text); } catch (e) {}
      }
      function isResults(t) {
        return t && t.length > 80 && t.indexOf('domain') !== -1 &&
               (t.indexOf('image_url') !== -1 || t.indexOf('backlink') !== -1);
      }
      var of = window.fetch;
      window.fetch = function () {
        return of.apply(this, arguments).then(function (r) {
          try { r.clone().text().then(function (t) { if (isResults(t)) send(t); }); } catch (e) {}
          return r;
        });
      };
      var send0 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        this.addEventListener('load', function () {
          try { if (isResults(this.responseText)) send(this.responseText); } catch (e) {}
        });
        return send0.apply(this, arguments);
      };
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let base64: String
        let onMatches: ([ImageMatch]) -> Void
        private var didDrop = false
        private var didDeliver = false
        private var pollCount = 0

        init(base64: String, onMatches: @escaping ([ImageMatch]) -> Void) {
            self.base64 = base64
            self.onMatches = onMatches
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, url.host?.contains("tineye.com") == true else { return }

            // Results page: if the JSON interceptor didn't catch it (server-rendered), scrape the DOM.
            if url.path.hasPrefix("/search/") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard !self.didDeliver else { return }
                    webView.evaluateJavaScript(Self.scrapeScript) { result, _ in
                        guard !self.didDeliver, let json = result as? String else { return }
                        let parsed = TinEyeParser.matches(from: json)
                        if !parsed.isEmpty { self.didDeliver = true; self.onMatches(parsed) }
                    }
                }
                return
            }

            // Homepage: drop the image into TinEye's upload flow once, then poll for results
            // (TinEye SPA-routes to /search/<hash> without a full navigation, so didFinish won't
            // fire there — polling the DOM is the reliable catch-all).
            guard url.path == "/" || url.path.isEmpty, !didDrop else { return }
            didDrop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                webView.evaluateJavaScript(Self.dropScript(self.base64), completionHandler: nil)
                self.pollForResults(webView)
            }
        }

        /// Periodically scrape the results page until matches appear or we give up.
        private func pollForResults(_ webView: WKWebView) {
            guard !didDeliver, pollCount < 14 else { return }
            pollCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak webView] in
                guard let self, let webView, !self.didDeliver else { return }
                guard let url = webView.url, url.path.hasPrefix("/search/") else {
                    self.pollForResults(webView); return
                }
                webView.evaluateJavaScript(Self.scrapeScript) { result, _ in
                    if !self.didDeliver, let json = result as? String {
                        let parsed = TinEyeParser.matches(from: json)
                        if !parsed.isEmpty {
                            self.didDeliver = true
                            self.onMatches(parsed)
                            return
                        }
                    }
                    self.pollForResults(webView)
                }
            }
        }

        /// Fallback: extract external links that have a thumbnail (skips nav/footer) from the
        /// rendered results page, shaped like the JSON parser expects.
        private static let scrapeScript = """
        (function () {
          var out = [], seen = {};
          var anchors = document.querySelectorAll('a[href^="http"]');
          for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i], href = a.href;
            if (href.indexOf('tineye.com') !== -1) continue;
            var box = a.closest('li,div,article') || a.parentElement;
            var img = box ? box.querySelector('img') : null;
            if (!img) continue;
            var d; try { d = new URL(href).hostname; } catch (e) { continue; }
            if (seen[href]) continue; seen[href] = 1;
            var title = (a.textContent || '').trim().slice(0, 140);
            out.push({ domain: d, url: href, image_url: img.src, title: title });
            if (out.length >= 60) break;
          }
          return JSON.stringify(out);
        })();
        """

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard !didDeliver, let body = message.body as? String, body.hasPrefix("json:") else { return }
            let json = String(body.dropFirst("json:".count))
            let parsed = TinEyeParser.matches(from: json)
            if !parsed.isEmpty {
                didDeliver = true
                onMatches(parsed)
            }
        }

        private static func dropScript(_ base64: String) -> String {
            """
            (function () {
              try {
                var bin = atob("\(base64)");
                var bytes = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                var file = new File([bytes], "image.jpg", { type: "image/jpeg" });
                var dt = new DataTransfer(); dt.items.add(file);
                function fire(type, target) {
                  var e = new DragEvent(type, { bubbles: true, cancelable: true });
                  try { Object.defineProperty(e, 'dataTransfer', { value: dt }); } catch (_) {}
                  target.dispatchEvent(e);
                }
                [window, document, document.body || document.documentElement].forEach(function (t) {
                  fire('dragenter', t); fire('dragover', t); fire('drop', t);
                });
              } catch (e) {}
            })();
            """
        }
    }
}

// MARK: - Flexible JSON parsing

enum TinEyeParser {
    static func matches(from jsonString: String) -> [ImageMatch] {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        guard let array = findMatchArray(root) else { return [] }
        return array.compactMap(parseMatch)
    }

    /// Recursively find the array of match dictionaries (objects containing "domain").
    private static func findMatchArray(_ obj: Any) -> [[String: Any]]? {
        if let array = obj as? [[String: Any]],
           array.contains(where: { $0["domain"] != nil || $0["backlinks"] != nil }) {
            return array
        }
        if let dict = obj as? [String: Any] {
            for value in dict.values {
                if let found = findMatchArray(value) { return found }
            }
        }
        if let array = obj as? [Any] {
            for value in array {
                if let found = findMatchArray(value) { return found }
            }
        }
        return nil
    }

    private static func parseMatch(_ dict: [String: Any]) -> ImageMatch? {
        let thumb = (dict["image_url"] as? String) ?? (dict["thumbnail"] as? String)

        var pageURLString = dict["url"] as? String
        var date = dict["crawl_date"] as? String
        if let backlinks = dict["backlinks"] as? [[String: Any]], let first = backlinks.first {
            pageURLString = (first["backlink"] as? String) ?? (first["url"] as? String) ?? pageURLString
            date = (first["crawl_date"] as? String) ?? date
        }

        let pageURL = pageURLString.flatMap { URL(string: $0) }
        let domain = (dict["domain"] as? String) ?? pageURL?.host ?? "Unknown"
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard pageURL != nil || thumb != nil else { return nil }
        return ImageMatch(domain: domain, title: title, pageURL: pageURL,
                          thumbURL: thumb.flatMap { URL(string: $0) }, date: date)
    }
}
