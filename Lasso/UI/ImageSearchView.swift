import SwiftUI
import WebKit
import AppKit

/// One reverse-image match, parsed from TinEye's results JSON.
struct ImageMatch: Identifiable {
    let id = UUID()
    let domain: String
    let pageURL: URL?
    let thumbURL: URL?
    let date: String?
}

/// Reverse-image search via TinEye, rendered **natively** in Lasso's style. A hidden WKWebView
/// loads tineye.com (a real WebKit view), receives a synthetic file-drop of the crop
/// into TinEye's own upload flow, and we intercept the results JSON TinEye fetches — then render a
/// clean native list (no TinEye chrome). Opt-in via ImageSearchAction. Spec §2/§17.
struct ImageSearchView: View {
    let image: CGImage

    @State private var matches: [ImageMatch] = []
    @State private var loading = true
    @State private var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(matches.isEmpty ? "Reverse image search"
                                      : "Reverse image search · \(matches.count) matches",
                      systemImage: "photo.badge.magnifyingglass")
                    .font(.headline)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { openInBrowserFallback() } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(IconButtonStyle())
                .help("Open TinEye in browser")
                Button { FloatingPanelController.shared.close() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Close")
            }

            if !matches.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { match in
                            MatchRow(match: match) { open($0) }
                        }
                    }
                }
                .frame(height: 360)
            } else {
                VStack(spacing: 8) {
                    if loading { ProgressView() }
                    Text(loading ? (slow ? "Still searching…" : "Searching TinEye…")
                                 : "No matches found.")
                        .font(.callout).foregroundStyle(.secondary)
                    if slow && loading {
                        Button("Open in browser instead") { openInBrowserFallback() }
                            .buttonStyle(.link)
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            }

            Label("Sent to TinEye — this leaves your Mac.", systemImage: "arrow.up.right")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 540)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .background(
            // Hidden worker webview: runs the search to get the JSON; never shown.
            TinEyeWorker(image: image) { found in
                if !found.isEmpty { matches = found }
                loading = false
            }
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
        )
        .task {
            try? await Task.sleep(for: .seconds(12))
            if loading { slow = true }
        }
    }

    /// Open a link in the browser. The floating results card stays on top (`.floating`), so the
    /// user can open several matches and only dismiss via ✕ / Esc.
    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func openInBrowserFallback() {
        Pasteboard.copy(image)
        open(URL(string: "https://tineye.com/")!)
    }
}

private struct MatchRow: View {
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
                    Text(match.domain).font(.callout.weight(.medium)).lineLimit(1)
                    if let url = match.pageURL {
                        Text(url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
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

private struct TinEyeWorker: NSViewRepresentable {
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
        webView.load(URLRequest(url: URL(string: "https://tineye.com/")!))
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

            // Homepage: drop the image into TinEye's upload flow once.
            guard url.path == "/" || url.path.isEmpty, !didDrop else { return }
            didDrop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                webView.evaluateJavaScript(Self.dropScript(self.base64), completionHandler: nil)
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
            out.push({ domain: d, url: href, image_url: img.src });
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
        guard pageURL != nil || thumb != nil else { return nil }
        return ImageMatch(domain: domain, pageURL: pageURL,
                          thumbURL: thumb.flatMap { URL(string: $0) }, date: date)
    }
}
