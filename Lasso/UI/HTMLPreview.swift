import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A page a package made (a console answer's `html`, docs/PACKAGES.md › Code blocks), shown in its
/// code block and, larger, in its own window. The page is the model's code, so it runs walled in:
/// JavaScript works, but it reaches no internet except cdnjs.cloudflare.com (and not even that in
/// local-only mode), reads no files outside its own folder, opens no popups, keeps nothing between
/// pages, and its links never navigate the view (a web link opens in the browser on a click). If the
/// walls can't be set up, the page isn't shown. The one thing it can tell Lasso is its script's error.
@MainActor
enum HTMLPreview {
    static let cdn = "cdnjs.cloudflare.com"
    /// Pages are served from their folder under this scheme, never as file:// URLs: a file page has no
    /// origin, so WebKit hides its own script errors ("Script error.") and file:// stays blocked.
    static let scheme = "lasso-page"

    /// WebKit content rules: block every load, then let the page's own folder, inline data and (unless
    /// local-only) the one script CDN through.
    static func rules(localOnly: Bool) -> String {
        var list: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for scheme in [scheme, "data", "blob", "about"] {
            list.append(["trigger": ["url-filter": "^\(scheme):"], "action": ["type": "ignore-previous-rules"]])
        }
        if !localOnly {
            list.append(["trigger": ["url-filter": "^https://cdnjs\\.cloudflare\\.com/"],
                         "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static var compiled: [Bool: WKContentRuleList] = [:]

    static func ruleList(localOnly: Bool) async throws -> WKContentRuleList {
        if let list = compiled[localOnly] { return list }
        let list = try await withCheckedThrowingContinuation { (done: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "lasso.htmlpreview.\(localOnly ? "local" : "cdn")",
                encodedContentRuleList: rules(localOnly: localOnly)) { list, error in
                    if let list { done.resume(returning: list) } else { done.resume(throwing: error ?? CocoaError(.featureUnsupported)) }
                }
        }
        compiled[localOnly] = list
        return list
    }

    static func webView(rules: WKContentRuleList, delegate: Walls) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(Folder(delegate.page.deletingLastPathComponent()), forURLScheme: scheme)
        config.userContentController.add(rules)
        // Its script's first error, as text, so the block can say why the page is blank.
        config.userContentController.addUserScript(WKUserScript(source: """
            window.addEventListener("error", function (e) {
              try { window.webkit.messageHandlers.lassoPageError.postMessage(String(e.message || "error").slice(0, 200)); } catch (_) {}
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(WeakHandler(delegate), name: "lassoPageError")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Pages are written for a white page; one that sets no background stays readable in dark mode.
        let web = PageWebView(frame: .zero, configuration: config)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsLinkPreview = false
        return web
    }

    /// Passes scrolling on to the chat while the whole page fits in the block, so the chat doesn't
    /// stall under the pointer.
    final class PageWebView: WKWebView {
        var passesScroll = false
        override func scrollWheel(with event: NSEvent) {
            if passesScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }
    }

    /// The content controller keeps its handler alive; this keeps it from keeping the page's delegate.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Walls?
        init(_ target: Walls) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String { target?.failed?(text) }
        }
    }

    static func load(_ url: URL, in web: WKWebView) {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "page"
        parts.path = "/" + url.lastPathComponent
        if let address = parts.url { web.load(URLRequest(url: address)) }
    }

    /// Serves the page's folder, and nothing outside it (no `..`, no links out).
    final class Folder: NSObject, WKURLSchemeHandler {
        let root: URL
        init(_ root: URL) { self.root = root.resolvingSymlinksInPath() }

        func file(for address: URL) -> URL? {
            let file = root.appending(path: String(address.path.drop(while: { $0 == "/" }))).standardizedFileURL.resolvingSymlinksInPath()
            return file.path.hasPrefix(root.path + "/") ? file : nil
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let address = task.request.url, let file = file(for: address), let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            var type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if type.hasPrefix("text/") || type.hasSuffix("javascript") || type.hasSuffix("xml") { type += "; charset=utf-8" }
            task.didReceive(HTTPURLResponse(url: address, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    /// Keeps the page on its own file: no navigating away, no popups. A click on a web link opens the
    /// browser instead (not in local-only mode).
    final class Walls: NSObject, WKNavigationDelegate, WKUIDelegate {
        let page: URL
        var finished: ((WKWebView) -> Void)?
        var failed: ((String) -> Void)?
        init(page: URL) { self.page = page }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == HTMLPreview.scheme { return .allow }   // its folder, served by Folder
            if ["about", "data", "blob"].contains(url.scheme ?? ""), action.targetFrame?.isMainFrame == false { return .allow }
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? ""), !PrivacyMode.localOnly {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?(webView) }
    }
}

/// The page, once its walls are up. `fitHeight` makes it as tall as its content (within limits), for
/// the code block; the window fills its space instead.
struct HTMLPreviewView: View {
    let url: URL
    var fitHeight: ClosedRange<CGFloat>?
    @State private var rules: WKContentRuleList?
    @State private var failed: String?
    @State private var height: CGFloat = 240
    @State private var scriptError: String?

    var body: some View {
        Group {
            if let rules {
                VStack(alignment: .leading, spacing: 4) {
                    Page(url: url, rules: rules, fit: fitHeight,
                         measured: { height = $0 }, failed: { if scriptError == nil { scriptError = $0 } })
                        .frame(height: fitHeight != nil ? height : nil)
                    if let scriptError {
                        Text("The page's script failed: \(scriptError)").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let failed {
                Text("Couldn't show the page: \(failed)").foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: url) {
            do { rules = try await HTMLPreview.ruleList(localOnly: PrivacyMode.localOnly) }
            catch { failed = error.localizedDescription }
        }
    }

    private struct Page: NSViewRepresentable {
        let url: URL
        let rules: WKContentRuleList
        let fit: ClosedRange<CGFloat>?
        let measured: (CGFloat) -> Void
        let failed: (String) -> Void

        func makeCoordinator() -> HTMLPreview.Walls { HTMLPreview.Walls(page: url) }

        func makeNSView(context: Context) -> WKWebView {
            let web = HTMLPreview.webView(rules: rules, delegate: context.coordinator)
            context.coordinator.failed = failed
            if let fit {
                let measured = measured
                // Measured when it loads and again a moment later, for pages that draw after loading.
                context.coordinator.finished = { web in
                    for delay in [0.0, 0.6] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            web.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") { value, _ in
                                guard let number = value as? NSNumber else { return }
                                let content = CGFloat(number.doubleValue)
                                (web as? HTMLPreview.PageWebView)?.passesScroll = content <= fit.upperBound
                                measured(min(max(content, fit.lowerBound), fit.upperBound))
                            }
                        }
                    }
                }
            }
            HTMLPreview.load(url, in: web)
            return web
        }

        func updateNSView(_ web: WKWebView, context: Context) {}
    }
}

/// The page in its own window, larger than the chat panel allows. Reused for the next page; Esc or ⌘W
/// closes it.
@MainActor
final class HTMLPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = HTMLPreviewWindow()
    private var window: NSWindow?

    func show(_ url: URL, title: String) {
        let view = HTMLPreviewWindowView(url: url) { [weak self] in self?.window?.close() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 360, height: 280)
            window.delegate = self
            window.center()
            return window
        }()
        window.title = title
        window.contentViewController = hosting
        if self.window == nil { window.setContentSize(NSSize(width: 900, height: 680)); window.center() }
        AppActivation.bringForward(window)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

private struct HTMLPreviewWindowView: View {
    let url: URL
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HTMLPreviewView(url: url).id(url)
            Divider()
            HStack(spacing: 8) {
                Text(PrivacyMode.localOnly ? "Runs offline (local-only mode)" : "Runs offline, except scripts from \(HTMLPreview.cdn)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if !PrivacyMode.localOnly {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                        .help("Your browser shows it without Lasso's limits: it can reach the internet")
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(10)
        }
    }
}
