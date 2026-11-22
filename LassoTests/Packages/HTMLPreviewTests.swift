import Foundation
import Testing
import WebKit
@testable import Lasso

/// The walls around a page a package shows (HTMLPreview): it can't reach any server or read files
/// outside its folder. Checked against a real local server that counts what reaches it, with a
/// control run without the walls so the check can fail.
@MainActor
@Suite(.serialized)
struct HTMLPreviewTests {
    /// A server on 127.0.0.1 that writes each request's path to a file.
    final class Server {
        let process = Process()
        let port: Int
        let log: URL
        init(folder: URL) throws {
            port = Int.random(in: 20_000...40_000)
            log = folder.appending(path: "hits.txt")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import http.server, sys
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    open(sys.argv[2], "a").write(self.path + "\\n")
                    self.send_response(200); self.send_header("Access-Control-Allow-Origin", "*"); self.end_headers(); self.wfile.write(b"ok")
                do_POST = do_GET
                def log_message(self, *a): pass
            http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
            """, "\(port)", log.path]
            try process.run()
        }
        var hits: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func ready() async throws {
            for _ in 0..<50 {
                if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ready")!)) != nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("server didn't start")
        }
        deinit { process.terminate() }
    }

    func page(_ folder: URL, port: Int) throws -> URL {
        let server = "http://127.0.0.1:\(port)"
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="\(server)/css">
        <script src="\(server)/script"></script>
        </head><body><h1>Hi</h1>
        <img src="\(server)/img">
        <iframe src="\(server)/frame"></iframe>
        <script>
        fetch("\(server)/fetch").catch(() => {});
        try { const x = new XMLHttpRequest(); x.open("GET", "\(server)/xhr"); x.send(); } catch (e) {}
        try { new WebSocket("ws://127.0.0.1:\(port)/ws"); } catch (e) {}
        navigator.sendBeacon && navigator.sendBeacon("\(server)/beacon", "x");
        fetch("file:///etc/hosts").then(r => r.text()).then(t => { document.title = "read:" + t.length }).catch(() => { document.title = "noread" });
        </script></body></html>
        """
        let url = folder.appending(path: "index.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    final class Finish: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    func load(_ url: URL, rules: WKContentRuleList?) async throws -> WKWebView {
        let walls = HTMLPreview.Walls(page: url)
        let web: WKWebView
        let finish = Finish()
        if let rules {
            web = HTMLPreview.webView(rules: rules, delegate: walls)
            walls.finished = { _ in finish.done = true }
        } else {
            web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            web.navigationDelegate = finish
        }
        if rules != nil { HTMLPreview.load(url, in: web) } else { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        for _ in 0..<100 where !finish.done { try await Task.sleep(for: .milliseconds(100)) }
        #expect(finish.done, "the page loaded")
        try await Task.sleep(for: .seconds(1.5))   // the page's fetches
        _ = walls
        return web
    }

    @Test func aPageReachesNoServerAndReadsNoOtherFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lasso-html-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try Server(folder: folder)
        try await server.ready()
        let url = try page(folder, port: server.port)

        // Control: without the walls the same page reaches the server, so this check can fail.
        let open = try await load(url, rules: nil)
        let reached = server.hits.filter { $0 != "/ready" }
        #expect(reached.count >= 3, "control run reached \(reached)")
        _ = open

        try "".write(to: server.log, atomically: true, encoding: .utf8)
        for localOnly in [false, true] {
            let web = try await load(url, rules: try await HTMLPreview.ruleList(localOnly: localOnly))
            #expect(server.hits.isEmpty, "walled page (local-only \(localOnly)) reached \(server.hits)")
            let title = try await web.evaluateJavaScript("document.title") as? String
            #expect(title != nil && !(title ?? "").hasPrefix("read:"), "read a file outside its folder: \(title ?? "")")
            let heading = try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String
            #expect(heading == "Hi", "the page itself still runs")
        }
    }

    @Test func aPageSaysWhenItsScriptFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lasso-html-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "index.html")
        try "<p>x</p><script>undefinedThing.go()</script>".write(to: url, atomically: true, encoding: .utf8)
        let walls = HTMLPreview.Walls(page: url)
        var errors: [String] = []
        walls.failed = { errors.append($0) }
        let web = HTMLPreview.webView(rules: try await HTMLPreview.ruleList(localOnly: true), delegate: walls)
        HTMLPreview.load(url, in: web)
        for _ in 0..<50 where errors.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(errors.first?.contains("undefinedThing") == true, "got \(errors)")
    }

    @Test func theFolderServesNothingOutsideIt() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lasso-html-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let folder = base.appending(path: "page", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret".write(to: base.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "out.txt"), withDestinationURL: base.appending(path: "secret.txt"))
        let served = HTMLPreview.Folder(folder)
        #expect(served.file(for: URL(string: "lasso-page://page/index.html")!) != nil)
        #expect(served.file(for: URL(string: "lasso-page://page/../secret.txt")!) == nil)
        #expect(served.file(for: URL(string: "lasso-page://page/%2E%2E/secret.txt")!) == nil)
        #expect(served.file(for: URL(string: "lasso-page://page/out.txt")!) == nil, "a link out of the folder")
    }

    @Test func onlyTheOneCDNAndNeverInLocalOnly() {
        #expect(HTMLPreview.rules(localOnly: false).contains("cdnjs"))
        #expect(!HTMLPreview.rules(localOnly: true).contains("cdnjs"))
    }

    @Test func aConsolePageMustBeHTMLOrSVGInItsOwnFolders() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lasso-page-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let places = PackageScript.Places(package: base.appending(path: "pkg"), data: base.appending(path: "data"),
                                          workspace: base.appending(path: "ws"), folders: [])
        for url in [places.package, places.data, places.workspace] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let page = places.workspace.appending(path: "index.html")
        try Data("<p>x</p>".utf8).write(to: page)
        let notes = places.workspace.appending(path: "notes.txt")
        try Data("x".utf8).write(to: notes)
        func parse(_ object: [String: Any]) throws -> PackageScript.Output {
            try PackageScript.parse(JSONSerialization.data(withJSONObject: object), places: places, tmp: base, id: "ws")
        }
        guard case .console(let console) = try parse(["console": "", "html": page.path]) else { Issue.record("not a console"); return }
        #expect(console.html?.lastPathComponent == "index.html")
        #expect(throws: (any Error).self) { _ = try parse(["console": "", "html": notes.path]) }
        #expect(throws: (any Error).self) { _ = try parse(["console": "", "html": "/etc/hosts"]) }
    }
}
