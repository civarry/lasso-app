import AppKit
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
    @State private var blockedURL: URL?

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
                LensWebView(image: image, loaded: $loaded, blockedURL: $blockedURL)
                if let blockedURL {
                    LensBlockedView(url: blockedURL).transition(.opacity)
                } else if !loaded {
                    LensSkeleton().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.25), value: loaded)
            .animation(.easeOut(duration: 0.25), value: blockedURL)
            // Safety net: reveal anyway if the page never signals ready (e.g. an unexpected
            // layout). Long enough to outlast a first-visit page load (see `LensSession.needsWarmUp`),
            // and it never reveals a blocked page: `blockedURL` is checked first above, and it is set
            // from the navigation delegate rather than from page JS, so detection does not depend on
            // an injected script running.
            .task { try? await Task.sleep(for: .seconds(10)); loaded = true }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassPanel()
    }
}

/// Shown in place of the web view when Google serves the "unusual traffic" interstitial instead of
/// results. That page is easier to use in a real browser than in this small panel, so the view offers
/// to open the same page there.
private struct LensBlockedView: View {
    let url: URL

    var body: some View {
        ZStack {
            Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255)   // Google's #202124
            VStack(spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.75))
                VStack(spacing: 4) {
                    Text("Google wants to verify you're not a bot")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("This can happen after several searches in a row. Open the page in your browser to complete the check, then try Lens again.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PressableStyle())
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            .padding(28)
            .frame(maxWidth: 320)
        }
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

/// Cookie/storage backing for the Lens web view.
///
/// Deliberately persistent: see the note in `LensWebView.makeNSView`. Isolated under its own
/// identifier so it holds only what Lens puts there, and clearable on demand.
@MainActor
enum LensSession {
    /// Stable identifier, so the same store is reused across launches.
    private static let storeID = UUID(uuidString: "6F1C6E28-4C6E-4E1E-9E2B-0B3B9C5A7D41")!

    static let dataStore = WKWebsiteDataStore(forIdentifier: storeID)

    /// The Safari version token to append to WebKit's own user agent.
    ///
    /// Read from the Safari installed on this Mac so it matches the real browser version. Lasso is not
    /// sandboxed (`Lasso/App/Lasso.entitlements`), so the read is permitted; the constant is only a
    /// fallback for the case where it fails.
    static let userAgentToken: String = {
        let fallback = "Version/18.6 Safari/605.1.15"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return fallback }
        return "Version/\(version) Safari/605.1.15"
    }()

    /// Smallest gap between two uploads, and the penalty once Google has actually pushed back.
    private static let minimumGap: TimeInterval = 2
    private static let blockedBackoff: TimeInterval = 60
    /// Earliest moment the next caller may upload.
    private static var nextStart = Date.distantPast
    /// Raised when Google pushes back. Re-read on every wake, so a block that lands while callers
    /// are already queued still delays them.
    private static var blockedUntil = Date.distantPast
    /// Tail of the queue. Each caller waits on its predecessor before it starts counting.
    private static var tail: Task<Void, Never>?

    /// Hold the caller until it is polite to issue another request, then claim the next slot.
    ///
    /// Keeps requests to Google at a modest rate: at most one upload every two seconds, so a burst of
    /// captures never turns into a burst of requests. Every upload path goes through here.
    ///
    /// Callers are chained rather than each sleeping against a shared deadline. The obvious version
    /// (read the deadline, sleep, write the deadline) reads and writes either side of a suspension
    /// point: `@MainActor` stops that being a data race, but every caller that arrives while an
    /// earlier one is asleep still reads the same unclaimed deadline and they all wake together.
    /// Measured, five searches 50 ms apart produced four simultaneous uploads. Taking a place in
    /// line before suspending is what actually serialises them.
    static func awaitTurn() async {
        let queuedAt = Date()
        let predecessor = tail
        let turn = Task { @MainActor in
            _ = await predecessor?.value          // our place in line, fixed before we suspend
            while !Task.isCancelled {
                let target = max(nextStart, blockedUntil)
                let wait = target.timeIntervalSinceNow
                if wait <= 0 { break }
                do { try await Task.sleep(for: .seconds(wait)) } catch { break }
                // loop rather than fall through: `blockedUntil` may have moved while we slept
            }
            nextStart = Date().addingTimeInterval(minimumGap)
        }
        tail = turn
        await turn.value
        Log.lens.debug("slot granted after \(Int(Date().timeIntervalSince(queuedAt) * 1000))ms")
    }

    /// The upload queued by the panel that is currently on screen, so dismissing it stops the request.
    ///
    /// Held here rather than torn down from `dismantleNSView`, because that hook never runs on the
    /// path the close button actually takes: `LensPanelController.close()` orders the window out and
    /// drops its reference, which does not dismantle the SwiftUI hierarchy. The upload task is
    /// unstructured and holds the web view strongly, so without this it still fires after the panel
    /// is gone.
    private static var pendingUpload: Task<Void, Never>?
    /// Whether `pendingUpload` already got its request out, so a later dismissal is not reported as
    /// having dropped anything.
    private static var uploadIssued = false

    /// Take ownership of the newly queued upload. A newer search supersedes whatever was waiting.
    static func register(_ upload: Task<Void, Never>) {
        pendingUpload?.cancel()
        pendingUpload = upload
        uploadIssued = false
    }

    /// The queued upload has left. Recorded so the dismissal log stays truthful.
    static func noteUploadIssued() { uploadIssued = true }

    /// Drop the queued upload. Called from `LensPanelController.close()`, which every dismissal and
    /// every new search goes through.
    static func cancelPendingUpload() {
        if pendingUpload != nil, !uploadIssued {
            Log.lens.debug("panel dismissed, dropping queued search")
        }
        pendingUpload?.cancel()
        pendingUpload = nil
    }

    /// Called when Google serves `/sorry`. Backs off every queued search, not just future ones:
    /// the search most likely to be in flight when a block lands is the one already waiting.
    static func noteBlocked() {
        blockedUntil = Date().addingTimeInterval(blockedBackoff)
        Log.lens.notice("blocked by /sorry, holding the next search for \(Int(blockedBackoff))s")
    }

    /// True when the jar holds no live `NID` cookie, i.e. this is the first visit.
    ///
    /// On a first visit the page is opened once before uploading, the same as a person opening
    /// lens.google.com in a browser, so Google's normal session cookies are in place. Cheap, because
    /// it only happens on a cold jar.
    static func needsWarmUp() async -> Bool {
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            dataStore.httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        return !cookies.contains { $0.name == "NID" && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    /// Wipe everything Lens has stored: cookies, caches, local storage. Not wired into Settings yet.
    static func clear() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
    }
}

/// Embeds a `WKWebView` that uploads the selection to Google Lens and shows the results.
private struct LensWebView: NSViewRepresentable {
    let image: CGImage
    @Binding var loaded: Bool
    @Binding var blockedURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: { loaded = true }, onBlocked: { url in blockedURL = url })
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent, app-scoped: Google's consent cookie survives between searches and across
        // launches, as it would in a browser. Scoped to its own identifier rather than `.default()`
        // so these cookies stay isolated from anything else the app loads in a web view. Nothing here
        // signs the user in; wipe it with `LensSession.clear()`.
        config.websiteDataStore = LensSession.dataStore
        // Append the installed Safari's version token. WKWebView's default user agent ends at
        // "(KHTML, like Gecko)" with no browser version. `applicationNameForUserAgent` appends only
        // the Version/Safari tokens and leaves WebKit's own build number in place.
        config.applicationNameForUserAgent = LensSession.userAgentToken
        // A user script runs *inside* the results page (so there's no navigation-delegate timing to
        // miss). It nudges the scroll to the matches, best-effort switches to English, and posts
        // `lensReady` once the final page is settled so the overlay can lift. It also watches for
        // Google's "unusual traffic" interstitial and posts `lensBlocked` instead, so we don't leave
        // the loading skeleton up over a page that will never send `lensReady`.
        let cc = WKUserContentController()
        cc.addUserScript(
            WKUserScript(source: Self.resultsPageJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cc.add(context.coordinator, name: "lensReady")
        cc.add(context.coordinator, name: "lensBlocked")
        config.userContentController = cc

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator   // also how `/sorry` is caught without page JS
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the page paints

        guard let base64 = ImageEncoder.jpegData(image, maxEdge: 1024, quality: 0.85)?
            .base64EncodedString() else { return web }

        // Wait our turn, warm the jar if Google has never seen us, and only then upload. The loading
        // overlay covers all of it, so the warm-up page is never visible.
        let coordinator = context.coordinator
        let upload = Task { @MainActor in
            guard !Task.isCancelled else {
                Log.lens.debug("search dropped before it started")
                return
            }
            // Warm up before taking a slot, so the slot is granted immediately before the upload
            // rather than before a navigation that can take a second. Otherwise two cold-jar searches
            // can be granted 2s apart and still reach Google closer together than that.
            if await LensSession.needsWarmUp() {
                Log.lens.debug("cold jar, warming up")
                if let home = URL(string: "https://lens.google.com/") {
                    await coordinator.navigate(web, to: home)
                }
            } else {
                Log.lens.debug("warm jar, skipping warm-up")
            }
            // If the warm-up itself came back blocked, uploading would post straight into the
            // interstitial we just detected, in the same instant we recorded the penalty for it.
            guard !Task.isCancelled, !coordinator.isBlocked else {
                Log.lens.debug("upload skipped after warm-up (cancelled: \(Task.isCancelled), blocked: \(coordinator.isBlocked))")
                return
            }
            await LensSession.awaitTurn()
            // Re-check both: the panel may have been dismissed or replaced while we held the queue,
            // and a `/sorry` may have landed on another search in the meantime.
            guard !Task.isCancelled, !coordinator.isBlocked else {
                Log.lens.debug("upload skipped at the gate (cancelled: \(Task.isCancelled), blocked: \(coordinator.isBlocked))")
                return
            }
            Log.lens.debug("uploading")
            LensSession.noteUploadIssued()
            web.loadHTMLString(Self.uploadHTML(base64: base64),
                               baseURL: URL(string: "https://lens.google.com/"))
        }
        coordinator.uploadTask = upload
        LensSession.register(upload)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Receives the `lensReady` / `lensBlocked` messages from the in-page script and lifts the loading
    /// overlay accordingly — `lensBlocked` carries the page's URL (as a string) so the caller can offer
    /// to open it in a real browser.
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onReady: () -> Void
        private let onBlocked: (URL?) -> Void
        private var pending: CheckedContinuation<Void, Never>?
        /// The queued warm-up-and-upload, so dismissing the panel can cancel it.
        var uploadTask: Task<Void, Never>?
        /// Set once `/sorry` has been seen on this web view, so we never upload into it.
        private(set) var isBlocked = false

        init(onReady: @escaping () -> Void, onBlocked: @escaping (URL?) -> Void) {
            self.onReady = onReady
            self.onBlocked = onBlocked
        }

        /// Load `url` and return once it has settled, so the warm-up finishes before the upload runs.
        func navigate(_ web: WKWebView, to url: URL) async {
            await withCheckedContinuation { c in
                pending = c
                web.load(URLRequest(url: url))
            }
        }

        private func finishPending() {
            pending?.resume()
            pending = nil
        }

        /// Report `/sorry` from the navigation itself, not from the injected script.
        ///
        /// The in-page script is best effort and can miss (CSP, a layout change, a document that
        /// never reaches `atDocumentEnd`). If it missed, the 10s safety net would lift the overlay
        /// and show Google's verification page inside a small panel, where it is hard to use. The URL
        /// is not best effort.
        private func checkBlocked(_ web: WKWebView) {
            guard let url = web.url, url.path.hasPrefix("/sorry") else { return }
            isBlocked = true
            LensSession.noteBlocked()
            onBlocked(url)
        }

        func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) {
            checkBlocked(web)
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            checkBlocked(web)
            finishPending()
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishPending()
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finishPending()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "lensReady":
                Log.lens.debug("results ready")
                onReady()
            case "lensBlocked":
                isBlocked = true
                LensSession.noteBlocked()
                onBlocked((message.body as? String).flatMap(URL.init(string:)))
            default: break
            }
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
    ///
    /// Separately, if Google serves the `/sorry/…` "unusual traffic" interstitial instead of results,
    /// post `lensBlocked` right away — that page never reaches `/search` and would otherwise leave the
    /// loading skeleton up forever, hiding Google's page behind a fake loading state.
    private static let resultsPageJS = """
    if (location.pathname.indexOf("/sorry") === 0) {
      (function () {
        try { window.webkit.messageHandlers.lensBlocked.postMessage(location.href); } catch (e) {}
      })();
    } else if (location.pathname.indexOf("/search") === 0) {
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
