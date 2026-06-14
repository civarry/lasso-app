import SwiftUI
import WebKit

/// Google Lens results rendered as a floating card — same chrome and anchoring as the Identify card,
/// so it lives "inside Lasso" next to the selection instead of in a separate app window.
///
/// The image is uploaded *from inside the web view* (a form POST on the `lens.google.com` origin), so
/// the redirect and the JS-rendered matches run in one continuous session — the only way the results
/// actually populate. See `LensWebView`.
struct LensResultView: View {
    let image: CGImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Google Lens", systemImage: "photo.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { LensPanelController.shared.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Close")
            }

            LensWebView(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

/// Embeds a `WKWebView` that uploads the selection to Google Lens and shows the results.
private struct LensWebView: NSViewRepresentable {
    let image: CGImage

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: a clean, logged-out session per upload — leaves nothing on disk.
        config.websiteDataStore = .nonPersistent()
        // A user script runs *inside* the results page (so there's no navigation-delegate timing to
        // miss). It nudges the scroll down to the matches and, best-effort, switches to English.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.resultsPageJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.userAgent
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the page paints
        if let base64 = ImageEncoder.jpegData(image, maxEdge: 1024, quality: 0.85)?.base64EncodedString() {
            web.loadHTMLString(Self.uploadHTML(base64: base64),
                               baseURL: URL(string: "https://lens.google.com/"))
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Runs only on the Lens results page. Does two best-effort things, each failing silently:
    ///   1. If Google is showing another language and offers an English *results* link, follow it
    ///      in-session (the page navigating itself — no 403). We only follow a link that keeps us on
    ///      the visual search (href has both "/search" and the "vsrid" token), so it can never jump to
    ///      the homepage, and we skip it once already on an `hl=en` URL so it can't loop.
    ///   2. Nudge the scroll down past the search box / image preview to the matches, re-asserting
    ///      against Google's scroll resets as it streams in the AI Overview.
    private static let resultsPageJS = """
    if (location.pathname.indexOf("/search") === 0) {
      (function () {
        var alreadyEnglish = /[?&]hl=en(&|$)/.test(location.search);
        var langTries = 0;
        function trySwitchLanguage() {
          if (alreadyEnglish) return;
          var links = document.querySelectorAll('a[href*="hl=en"]');
          for (var i = 0; i < links.length; i++) {
            var a = links[i];
            // Check the link's *parsed* host/path, not raw substrings — otherwise the "Sign in" link
            // (accounts.google.com/ServiceLogin?continue=…/search?vsrid=…) matches and hijacks us to
            // the login page. The real "switch to English" link is itself a google.com/search result.
            if (a.hostname.indexOf("google.com") !== -1 &&
                a.hostname.indexOf("accounts.") === -1 &&
                a.pathname.indexOf("/search") === 0 &&
                /[?&]hl=en(&|$)/.test(a.search) &&
                a.search.indexOf("vsrid") !== -1) {
              location.href = a.href; return;
            }
          }
          if (langTries++ < 20) setTimeout(trySwitchLanguage, 200);
        }
        setTimeout(trySwitchLanguage, 400);

        var target = 90, settles = 0, waits = 0;
        function el() { return document.scrollingElement || document.documentElement; }
        function go() {
          var e = el();
          if (e && e.scrollHeight - e.clientHeight > 120) {
            e.scrollTop = target;
            if (settles < 8) { settles++; setTimeout(go, 350); }
          } else if (waits < 40) { waits++; setTimeout(go, 150); }
        }
        setTimeout(go, 300);
      })();
    }
    """

    /// A tiny page on the `lens.google.com` origin that rebuilds the image as a file and submits it to
    /// the upload endpoint. A real form submit (not `fetch`) lets the browser follow the cross-origin
    /// redirect natively and render the results — no CORS wall, no session loss.
    private static func uploadHTML(base64: String) -> String {
        let stcs = Int(Date().timeIntervalSince1970)
        return """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body style="margin:0;background:#202124;color:#9aa0a6;\
        font:15px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:100vh">
        Searching Google Lens…
        <form id="f" method="POST" enctype="multipart/form-data"
              action="https://lens.google.com/v3/upload?stcs=\(stcs)"></form>
        <script>
        (function () {
          var b64 = "\(base64)";
          var bin = atob(b64), arr = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
          var blob = new Blob([arr], { type: "image/jpeg" });
          var input = document.createElement("input");
          input.type = "file"; input.name = "encoded_image";
          var dt = new DataTransfer();
          dt.items.add(new File([blob], "capture.jpg", { type: "image/jpeg" }));
          input.files = dt.files;
          var f = document.getElementById("f");
          f.appendChild(input);
          f.submit();
        })();
        </script></body></html>
        """
    }
}
