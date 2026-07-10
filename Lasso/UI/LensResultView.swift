import SwiftUI
import WebKit

/// Google Lens results rendered as a floating card — same chrome and anchoring as the Identify card,
/// so it lives "inside Lasso" next to the selection instead of in a separate app window.
///
/// The image is uploaded *from inside the web view* (a form POST on the `lens.google.com` origin), so
/// the redirect and the JS-rendered matches run in one continuous session — the only way the results
/// actually populate. See `LensWebView`. A loading overlay hides the upload page (and any language
/// redirect) until the results are ready, so the user only ever sees a spinner → the results.
struct LensResultView: View {
    let image: CGImage
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Lens", systemImage: "photo.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { LensPanelController.shared.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Close")
            }

            ZStack {
                LensWebView(image: image, loaded: $loaded)
                if !loaded {
                    LensSkeleton().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.25), value: loaded)
            // Safety net: reveal anyway if the page never signals ready (e.g. an unexpected layout).
            .task { try? await Task.sleep(for: .seconds(6)); loaded = true }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassPanel()
    }
}

/// Skeleton placeholder shown over the web view until the real Lens results are ready. Mirrors the
/// rough layout (search bar, tabs, AI Overview, result cards) and pulses, so loading reads as "the
/// page is coming" rather than a bare spinner.
private struct LensSkeleton: View {
    @State private var pulse = false

    private func block(_ width: CGFloat? = nil, height: CGFloat, corner: CGFloat = 7) -> some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(Color.white.opacity(0.09))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255)   // Google's #202124
            VStack(alignment: .leading, spacing: 20) {
                block(height: 44, corner: 22)                       // search bar
                HStack(spacing: 16) {                               // tabs
                    ForEach(0..<5, id: \.self) { _ in block(54, height: 13) }
                }
                VStack(alignment: .leading, spacing: 11) {          // AI Overview
                    block(120, height: 16)
                    block(height: 12); block(height: 12)
                    block(240, height: 12)
                }
                ForEach(0..<2, id: \.self) { _ in                   // result cards
                    HStack(spacing: 12) {
                        block(64, height: 64, corner: 10)
                        VStack(alignment: .leading, spacing: 9) {
                            block(height: 12)
                            block(170, height: 12)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .opacity(pulse ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}

/// Embeds a `WKWebView` that uploads the selection to Google Lens and shows the results.
private struct LensWebView: NSViewRepresentable {
    let image: CGImage
    @Binding var loaded: Bool

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func makeCoordinator() -> Coordinator { Coordinator { loaded = true } }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: a clean, logged-out session per upload — leaves nothing on disk.
        config.websiteDataStore = .nonPersistent()
        // A user script runs *inside* the results page (so there's no navigation-delegate timing to
        // miss). It nudges the scroll to the matches, best-effort switches to English, and posts
        // `lensReady` once the final page is settled so the overlay can lift.
        let cc = WKUserContentController()
        cc.addUserScript(
            WKUserScript(source: Self.resultsPageJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cc.add(context.coordinator, name: "lensReady")
        config.userContentController = cc

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

    /// Receives the `lensReady` message from the in-page script and lifts the loading overlay.
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onReady: () -> Void
        init(onReady: @escaping () -> Void) { self.onReady = onReady }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "lensReady" { onReady() }
        }
    }

    /// Runs only on the Lens results page. Best-effort, each step failing silently:
    ///   1. If Google shows another language and offers an English *results* link, follow it in-session
    ///      (no 403). We match the link's parsed host/path (not raw substrings) so the "Sign in" link
    ///      — accounts.google.com/ServiceLogin?continue=…/search?vsrid=… — can't hijack us to login, and
    ///      we skip it once already on `hl=en` so it can't loop.
    ///   2. Nudge the scroll down to the matches, re-asserting against Google's scroll resets.
    ///   3. Post `lensReady` once we're settled on the final page so Swift lifts the loading overlay —
    ///      held back while a language switch is still pending so the redirect stays hidden.
    private static let resultsPageJS = """
    if (location.pathname.indexOf("/search") === 0) {
      (function () {
        function ready() { try { window.webkit.messageHandlers.lensReady.postMessage(1); } catch (e) {} }
        var alreadyEnglish = /[?&]hl=en(&|$)/.test(location.search);
        var canReveal = alreadyEnglish;   // already English: nothing to switch, free to reveal
        var langTries = 0;

        function trySwitchLanguage() {
          var links = document.querySelectorAll('a[href*="hl=en"]');
          for (var i = 0; i < links.length; i++) {
            var a = links[i];
            if (a.hostname.indexOf("google.com") !== -1 &&
                a.hostname.indexOf("accounts.") === -1 &&
                a.pathname.indexOf("/search") === 0 &&
                /[?&]hl=en(&|$)/.test(a.search) &&
                a.search.indexOf("vsrid") !== -1) {
              location.href = a.href; return;   // navigate; the English page reveals itself
            }
          }
          if (langTries++ < 5) { setTimeout(trySwitchLanguage, 150); }
          else { canReveal = true; }            // no English link — reveal current language
        }
        if (!alreadyEnglish) setTimeout(trySwitchLanguage, 150);

        var target = 90, revealed = false, ticks = 0;
        function el() { return document.scrollingElement || document.documentElement; }
        function contentReady() {
          var txt = (document.body && document.body.innerText) ? document.body.innerText.trim().length : 0;
          return txt > 250 || (el().scrollHeight - el().clientHeight) > 120;
        }
        function tick() {
          if (!revealed && canReveal && contentReady()) {
            revealed = true;
            el().scrollTop = target;
            ready();   // lift the overlay the moment real results are on screen
            var n = 0;  // keep re-asserting the scroll against Google's resets
            (function reassert() { el().scrollTop = target; if (n++ < 6) setTimeout(reassert, 300); })();
            return;
          }
          if (ticks++ < 50) setTimeout(tick, 100);
        }
        setTimeout(tick, 120);
      })();
    }
    """

    /// A tiny page on the `lens.google.com` origin that rebuilds the image as a file and submits it to
    /// the upload endpoint. A real form submit (not `fetch`) lets the browser follow the cross-origin
    /// redirect natively and render the results — no CORS wall, no session loss. The form is hidden;
    /// the loading overlay covers this page anyway.
    private static func uploadHTML(base64: String) -> String {
        let stcs = Int(Date().timeIntervalSince1970)
        return """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body style="margin:0;background:#202124">
        <form id="f" method="POST" enctype="multipart/form-data" style="display:none"
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
