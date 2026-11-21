import Foundation
import Testing
@testable import Lasso

/// The checks `docs/PACKAGES.md` lists under Verification for build step 1. Network checks run
/// against `RecordingServer` on loopback; nothing reaches the internet.
@Suite(.serialized)
struct PackageValidatorTests {
    private func validate(_ json: String) -> PackageValidator.Outcome {
        PackageValidator.validate(Data(json.utf8), lassoVersion: "0.17.0")
    }

    private func messages(_ json: String) -> [String] { validate(json).problems.map(\.description) }

    /// A valid search package to vary.
    static let search = """
    {"lasso": 1, "id": "brave-search", "version": "1.0.0", "name": "Brave", "summary": "Search.", "author": "Me",
     "hosts": ["api.search.brave.com"],
     "settings": [{"id": "key", "label": "API key", "kind": "secret"}],
     "commands": [{"id": "search", "title": "Brave", "surfaces": ["search"], "input": ["query"], "output": "results",
       "run": {"http": {"url": "https://api.search.brave.com/res/v1/web/search", "query": {"q": "{{query}}"},
                        "headers": {"X-Subscription-Token": "{{settings.key}}"}},
               "results": {"list": "web.results", "title": "title", "url": "url", "snippet": "description"}},
       "test": {"query": "lasso"}}]}
    """

    @Test func theBundledPackagesAreValid() throws {
        for id in BundledPackages.ids {
            let data = try #require(BundledPackages.data(id), "\(id) isn't bundled")
            let outcome = PackageValidator.validate(data)
            #expect(outcome.package?.id == id, "\(outcome.problems)")
        }
        #expect(validate(Self.search).package != nil, "\(validate(Self.search).problems)")
    }

    @Test func aNewerFormatIsRefused() {
        #expect(messages(Self.search.replacingOccurrences(of: "\"lasso\": 1", with: "\"lasso\": 2"))
            .contains { $0.hasPrefix("lasso: Needs a newer Lasso") })
    }

    @Test func unknownFieldsAreRefusedByName() {
        let typo = Self.search
            .replacingOccurrences(of: "\"author\": \"Me\"", with: "\"author\": \"Me\", \"autor\": \"x\"")
            .replacingOccurrences(of: "\"title\": \"Brave\"", with: "\"title\": \"Brave\", \"titel\": 1")
            .replacingOccurrences(of: "\"query\": {\"q\"", with: "\"qurey\": 1, \"query\": {\"q\"")
        let found = messages(typo)
        #expect(found.contains("autor: Unknown field \"autor\"."))
        #expect(found.contains("commands[0].titel: Unknown field \"titel\"."))
        #expect(found.contains("commands[0].run.http.qurey: Unknown field \"qurey\"."))
    }

    @Test func unknownTemplateNamesAreRefused() {
        let found = messages(Self.search
            .replacingOccurrences(of: "{{settings.key}}", with: "{{settings.nope}}")
            .replacingOccurrences(of: "\"q\": \"{{query}}\"", with: "\"q\": \"{{qurey}}\", \"t\": \"{{text}}\""))
        #expect(found.contains { $0.contains("{{settings.nope}}") })
        #expect(found.contains { $0.contains("{{qurey}}") })
        #expect(found.contains { $0.contains("{{text}}") }, "text isn't an input of a search command")
    }

    @Test func aSearchCommandHasItsShape() {
        let noTest = messages(Self.search.replacingOccurrences(of: #",\s*"test": \{"query": "lasso"\}"#, with: "", options: .regularExpression))
        #expect(noTest.contains { $0.hasPrefix("commands[0].test:") })
        let wrongOutput = messages(Self.search.replacingOccurrences(of: "\"output\": \"results\"", with: "\"output\": \"markdown\""))
        #expect(wrongOutput.contains { $0.hasPrefix("commands[0].output:") })
    }

    @Test func hostsAndSchemes() {
        let plainHTTP = messages(Self.search.replacingOccurrences(of: "https://api.search.brave.com", with: "http://api.search.brave.com"))
        #expect(plainHTTP.contains("commands[0].run.http.url: Must be https."))
        let undeclared = messages(Self.search.replacingOccurrences(of: "https://api.search.brave.com", with: "https://evil.example.com"))
        #expect(undeclared.contains { $0.contains("\"evil.example.com\" isn't in hosts") })
        let templatedHost = messages(Self.search.replacingOccurrences(of: "https://api.search.brave.com/", with: "https://{{query}}.brave.com/"))
        #expect(templatedHost.contains { $0.contains("Templates can't change the host") })
        let wildcard = messages(Self.search.replacingOccurrences(of: "[\"api.search.brave.com\"]", with: "[\"*.brave.com\"]"))
        #expect(wildcard.contains { $0.hasPrefix("hosts[0]:") })
        // Plain http only through a server setting, for a server on this Mac.
        let server = Self.search
            .replacingOccurrences(of: "{\"id\": \"key\", \"label\": \"API key\", \"kind\": \"secret\"}",
                                  with: "{\"id\": \"key\", \"label\": \"API key\", \"kind\": \"secret\"}, {\"id\": \"server\", \"label\": \"Server\", \"kind\": \"server\"}")
            .replacingOccurrences(of: "https://api.search.brave.com/res/v1/web/search", with: "{{settings.server}}/search")
            .replacingOccurrences(of: "\"hosts\": [\"api.search.brave.com\"],", with: "")
        #expect(validate(server).package != nil, "\(validate(server).problems)")
    }

    @Test func partsNotBuiltYetAreRefusedClearly() {
        let prompt = messages(Self.search.replacingOccurrences(of: "\"run\": {\"http\"", with: "\"run\": {\"prompt\": \"x\", \"http\""))
        #expect(prompt.contains("commands[0].run: Use one runner, not http and prompt."))
        let image = messages(Self.search.replacingOccurrences(of: "\"input\": [\"query\"]", with: "\"input\": [\"query\", \"image\"]"))
        #expect(image.contains { $0.contains("can't give commands images yet") }, "\(image)")
        let script = messages(Self.search.replacingOccurrences(of: "\"run\": {\"http\"", with: "\"run\": {\"script\": {}, \"http\""))
        #expect(script.contains("commands[0].run: Use one runner, not http and script."))
    }

    @Test func minLasso() {
        let tooNew = messages(Self.search.replacingOccurrences(of: "\"author\": \"Me\"", with: "\"author\": \"Me\", \"minLasso\": \"0.18.0\""))
        #expect(tooNew.contains { $0.hasPrefix("minLasso: Needs Lasso 0.18.0") })
        #expect(validate(Self.search.replacingOccurrences(of: "\"author\": \"Me\"", with: "\"author\": \"Me\", \"minLasso\": \"0.16.10\"")).package != nil)
    }

    @Test func theSchemaLineIsAllowed() {
        let withSchema = Self.search.replacingOccurrences(of: "{\"lasso\": 1,", with: "{\"$schema\": \"https://example.com/s.json\", \"lasso\": 1,")
        #expect(validate(withSchema).package != nil, "\(validate(withSchema).problems)")
    }

    /// The example in docs/CONTRIBUTING-PACKAGES.md is valid as written.
    @Test func theGuidesExampleIsValid() throws {
        #expect(validate(PackageLiveTests.wikipedia).package != nil, "\(validate(PackageLiveTests.wikipedia).problems)")
    }

    @Test func notAPackage() {
        #expect(messages("[1, 2]") == ["This isn't a package: it must be a JSON object."])
        #expect(messages("not json") == ["This isn't a package: it must be a JSON object."])
    }
}

@Suite(.serialized)
struct PackageHTTPTests {
    private func run(_ package: String) throws -> (LassoPackage, PackageCommand) {
        let p = try #require(PackageValidator.validate(Data(package.utf8), lassoVersion: "0.17.0").package)
        return (p, p.commands[0])
    }

    /// The same search package, pointed at a server on this Mac.
    private func local(_ extra: String = "", http: String) -> String {
        """
        {"lasso": 1, "id": "local-search", "version": "1.0.0", "name": "Local", "summary": "S.", "author": "Me",
         "settings": [{"id": "server", "label": "Server", "kind": "server"}, {"id": "key", "label": "Key", "kind": "secret"}],
         "commands": [{"id": "search", "title": "Local", "surfaces": ["search"], "input": ["query"], "output": "results",
           "run": {"http": \(http), "results": {"list": "items", "title": "t", "url": "u", "snippet": "s", "limit": 3}},
           "test": {"query": "x"}}]\(extra)}
        """
    }

    @Test func valuesArriveIntactWhereverTheyLand() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        let tricky = "a&b #c \"d\"\ne=f+g/h?"
        let (package, command) = try run(local(http: """
            {"method": "POST", "url": "{{settings.server}}/p/{{query}}?inline={{query}}", "query": {"q": "{{query}}"},
             "headers": {"X-Key": "{{settings.key}}"}, "json": {"query": "{{query}}", "n": 6}}
            """))
        let values = ["settings.server": server.base, "settings.key": "k-123", "query": tricky]
        let request = try PackageHTTP.request(command.http!, values: values)
        _ = try await PackageHTTP.send(request, allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
        let got = try #require(server.requests.first)
        #expect(got.path.removingPercentEncoding == "/p/\(tricky)")
        let items = URLComponents(string: "x:/?\(got.query)")?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == tricky)
        #expect(items.first { $0.name == "inline" }?.value == tricky)
        let body = try #require(try JSONSerialization.jsonObject(with: got.body) as? [String: Any])
        #expect(body["query"] as? String == tricky)
        #expect(body["n"] as? Int == 6)
        #expect(got.headers["x-key"] == "k-123")
        #expect(got.headers["user-agent"]?.hasPrefix("Lasso/") == true)
        #expect(got.headers["cookie"] == nil)

        // A form body too.
        let (_, form) = try run(local(http: """
            {"method": "POST", "url": "{{settings.server}}/f", "form": {"q": "{{query}}"}}
            """))
        _ = try await PackageHTTP.send(try PackageHTTP.request(form.http!, values: values),
                                       allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
        let lastRequest = try #require(server.requests.last)
        let formBody = String(decoding: lastRequest.body, as: UTF8.self)
        #expect(URLComponents(string: "x:/?\(formBody)")?.queryItems?.first?.value == tricky)
    }

    @Test func aHeaderWithALineBreakIsRefused() throws {
        let (_, command) = try run(local(http: """
            {"url": "{{settings.server}}/h", "headers": {"X-Key": "{{settings.key}}"}}
            """))
        #expect(throws: PackageHTTP.RunError.headerLineBreak("X-Key")) {
            try PackageHTTP.request(command.http!, values: ["settings.server": "http://127.0.0.1:9", "settings.key": "a\r\nInjected: 1"])
        }
    }

    @Test func undeclaredHostsAreRefusedAndNotFollowed() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        let (package, command) = try run(local(http: "{\"url\": \"{{settings.server}}/r\"}"))
        let values = ["settings.server": server.base, "query": "x"]
        // Before connecting: a host it didn't declare.
        var request = try PackageHTTP.request(command.http!, values: values)
        request.url = URL(string: "http://localhost:\(server.port)/other")
        await #expect(throws: PackageHTTP.RunError.undeclaredHost("localhost")) {
            _ = try await PackageHTTP.send(request, allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
        }
        #expect(server.requests.isEmpty, "it connected to an undeclared host")
        // A redirect to one isn't followed.
        server.answer(.init(status: 302, body: Data(), location: "http://localhost:\(server.port)/stolen"))
        await #expect(throws: PackageHTTP.RunError.undeclaredHost("localhost")) {
            _ = try await PackageHTTP.send(try PackageHTTP.request(command.http!, values: values),
                                           allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
        }
        #expect(server.requests.map(\.path) == ["/r"], "the redirect was followed")
    }

    @Test func localOnlyStopsOffMacRequestsInTheEngine() async throws {
        let (package, command) = try run(PackageValidatorTests.search)
        let values = ["settings.key": "k", "query": "x"]
        await #expect(throws: PackageHTTP.RunError.localOnly) {
            _ = try await PackageHTTP.send(try PackageHTTP.request(command.http!, values: values),
                                           allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: true)
        }
        // A server on this Mac keeps working.
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(body: Data("{\"items\": []}".utf8)))
        let (lp, lc) = try run(local(http: "{\"url\": \"{{settings.server}}/s\"}"))
        let lv = ["settings.server": server.base, "query": "x"]
        _ = try await PackageHTTP.send(try PackageHTTP.request(lc.http!, values: lv), allowed: PackageHTTP.allowedHosts(lp, values: lv), localOnly: true)
        #expect(server.requests.count == 1)
    }

    @Test func responsesAreLimitedAndTrimmed() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        let (package, command) = try run(local(http: "{\"url\": \"{{settings.server}}/s\"}"))
        let values = ["settings.server": server.base, "query": "x"]
        server.answer(.init(body: Data(("{\"items\": [\"" + String(repeating: "x", count: 3 * 1024 * 1024) + "\"]}").utf8)))
        await #expect(throws: PackageHTTP.RunError.tooLarge) {
            _ = try await PackageHTTP.send(try PackageHTTP.request(command.http!, values: values),
                                           allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
        }
        let long = String(repeating: "t", count: 300), snippet = String(repeating: "s", count: 900)
        let items = (0..<5).map { ["t": "\(long)\($0)", "u": $0 == 0 ? "javascript:alert(1)" : "https://e.com/\($0)", "s": snippet] }
        let json: [String: Any] = ["items": items]
        let map = try #require(command.http!.results)
        let hits = PackageHTTP.results(json, map: map, source: "Local")
        #expect(hits.count == 3)
        #expect(hits.allSatisfy { $0.title.count == 200 && ($0.snippet?.count ?? 0) == 500 && $0.source == "Local" })
        #expect(hits[0].url == nil, "a non-web link must not become a source link")
        #expect(PackageHTTP.plain("<span class=\"searchmatch\">Ada</span> &amp; Charles\n  Babbage") == "Ada & Charles Babbage")
        #expect(PackageHTTP.value(["a": [["b": 1]]], at: "a.0.b") as? Int == 1)
        #expect(PackageHTTP.value(["a": 1], at: "a.b") == nil)
    }

    @Test func secretsAreRedacted() {
        let line = PackageHTTP.redact("GET https://serpapi.com/search.json?api_key=sk%2Fabc%3D%3D&q=x key=sk/abc==",
                                      secrets: ["sk/abc=="])
        #expect(!line.contains("sk/abc==") && !line.contains("sk%2Fabc"))
        #expect(line.contains("•••"))
    }

    /// Tavily and SerpApi as packages send what the Swift code did (it's gone, so its requests are
    /// written out here from the last version).
    @Test func tavilyAndSerpApiSendTheSameRequests() throws {
        let tavilyData = try #require(BundledPackages.data("tavily"))
        let tavily = try #require(PackageValidator.validate(tavilyData).package)
        let t = try PackageHTTP.request(tavily.commands[0].http!, values: ["settings.key": "tvly-k", "query": "mars rover"])
        #expect(t.url?.absoluteString == "https://api.tavily.com/search")
        #expect(t.httpMethod == "POST")
        #expect(t.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-k")
        let tBody = try #require(t.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: tBody) as? [String: AnyHashable])
        #expect(body == ["api_key": "tvly-k", "query": "mars rover", "max_results": 6, "search_depth": "basic"])

        let serpData = try #require(BundledPackages.data("serpapi"))
        let serp = try #require(PackageValidator.validate(serpData).package)
        let s = try PackageHTTP.request(serp.commands[0].http!, values: ["settings.key": "sk", "query": "mars rover"])
        let sURL = try #require(s.url)
        let items = Set(URLComponents(url: sURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        #expect(s.url?.host == "serpapi.com" && s.url?.path == "/search.json" && s.httpMethod == "GET")
        #expect(items == [URLQueryItem(name: "engine", value: "google"), URLQueryItem(name: "num", value: "8"),
                          URLQueryItem(name: "q", value: "mars rover"), URLQueryItem(name: "api_key", value: "sk")])
        // Same limits as the old quota table, and reserve below 5 results.
        #expect(tavily.limits == PackageLimits(daily: 40, monthly: 960) && tavily.commands[0].http!.role == .primary)
        #expect(serp.limits == PackageLimits(daily: 10, monthly: 240) && serp.commands[0].http!.role == .reserve)
        #expect(WebSourcesProvider.reserveThreshold == 5)
        // Results map the same fields the Swift code read.
        let hits = PackageHTTP.results(["results": [["title": "T", "url": "https://a.com", "content": "C"]]],
                                       map: tavily.commands[0].http!.results!, source: tavily.name)
        #expect(hits.first?.title == "T" && hits.first?.snippet == "C" && hits.first?.source == "Tavily")
    }
}

@MainActor
@Suite(.serialized)
struct PackageStoreTests {
    private func temp() -> (PackageStore, UserDefaults, URL) {
        let name = "lasso-tests-packages-\(UUID().uuidString.prefix(6))"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        return (PackageStore(root: root, defaults: defaults), defaults, root)
    }

    private func manifest(id: String, version: String = "1.0.0") -> Data {
        Data(PackageValidatorTests.search
            .replacingOccurrences(of: "\"id\": \"brave-search\"", with: "\"id\": \"\(id)\"")
            .replacingOccurrences(of: "\"version\": \"1.0.0\"", with: "\"version\": \"\(version)\"").utf8)
    }

    @Test func installUpdateRemove() throws {
        let (store, defaults, root) = temp()
        defer { try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        let id = "test-\(UUID().uuidString.prefix(6).lowercased())"
        let package = try store.install(manifest(id: id), origin: .file)
        #expect(store.installed.map(\.id) == [id] && store.installed[0].enabled)

        // Settings: a secret in the Keychain, scoped to the package.
        let key = try #require(package.setting("key"))
        store.setValue("secret-1", id, key)
        #expect(store.value(id, key) == "secret-1")
        #expect(store.settingValues(for: package).values["settings.key"] == "secret-1")

        // Same version again: refused. Newer: updates, and the key carries over.
        #expect(throws: PackageStore.InstallError.alreadyInstalled("1.0.0")) { try store.install(manifest(id: id), origin: .file) }
        try store.install(manifest(id: id, version: "1.1.0"), origin: .file)
        #expect(store.installed[0].package.version == "1.1.0" && store.value(id, key) == "secret-1")

        // Removing deletes the files, the record and the key.
        store.remove(id)
        #expect(store.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: id).path))
        #expect(Keychain.get("package.\(id).key") == nil)
        _ = defaults
    }

    @Test func aManifestChangedOnDiskIsTurnedOff() throws {
        let (store, _, root) = temp()
        defer { try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        let id = "test-\(UUID().uuidString.prefix(6).lowercased())"
        try store.install(manifest(id: id), origin: .file)
        // Something other than Lasso edits it (a wider host list, say).
        let edited = String(decoding: manifest(id: id), as: UTF8.self).replacingOccurrences(of: "\"name\": \"Brave\"", with: "\"name\": \"Brave!\"")
        try Data(edited.utf8).write(to: root.appending(path: "\(id)/lasso.json"))
        store.reload()
        #expect(store.installed[0].changedOnDisk && !store.installed[0].enabled)
        // The review compares against what was approved, kept where the package's files can't reach.
        #expect(store.installed[0].approved?.name == "Brave" && store.installed[0].package.name == "Brave!")
        // The switch can't approve it: a changed package comes back only through the review.
        store.setEnabled(id, true)
        #expect(!store.installed[0].enabled && store.installed[0].changedOnDisk)
        store.approveChange(id)
        #expect(store.installed[0].enabled && !store.installed[0].changedOnDisk)
    }

    @Test func aBrokenPackageIsListedNotLoaded() throws {
        let (store, defaults, root) = temp()
        defer { try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        let id = "test-\(UUID().uuidString.prefix(6).lowercased())"
        try store.install(manifest(id: id), origin: .file)
        try Data("{\"lasso\": 1}".utf8).write(to: root.appending(path: "\(id)/lasso.json"))
        store.reload()
        #expect(store.installed.isEmpty && store.broken.map(\.id) == [id])
        _ = defaults
    }

    @Test func migrationMovesKeysOnce() throws {
        let (store, defaults, root) = temp()
        defer {
            try? FileManager.default.removeItem(at: root)
            for id in BundledPackages.ids { Keychain.delete("package.\(id).key") }
            PackageStore.shared.reload()
        }
        var keys = ["tavily.apiKey": "tvly-old", "serpapi.apiKey": "serp-old"]
        defaults.set(true, forKey: "connector.tavily.enabled")
        defaults.set(false, forKey: "connector.serpapi.enabled")
        PackageMigration.run(store: store, defaults: defaults, readKey: { keys[$0] }, deleteKey: { keys[$0] = nil })
        #expect(Set(store.installed.map(\.id)) == ["tavily", "serpapi"])
        #expect(store.installed.first { $0.id == "tavily" }?.enabled == true)
        #expect(store.installed.first { $0.id == "serpapi" }?.enabled == false, "an off connector stays off")
        #expect(Keychain.get("package.tavily.key") == "tvly-old" && Keychain.get("package.serpapi.key") == "serp-old")
        #expect(keys.isEmpty, "the old keys are moved, not copied")
        #expect(store.installed.allSatisfy { $0.origin == .bundled })
        // Usage counts carry over: the packages count under the old counters' names.
        #expect(BundledPackages.ids == ["tavily", "serpapi"])

        // Once: a second run with a key saved again installs nothing more.
        store.remove("serpapi")
        keys["serpapi.apiKey"] = "again"
        PackageMigration.run(store: store, defaults: defaults, readKey: { keys[$0] }, deleteKey: { keys[$0] = nil })
        #expect(!store.isInstalled("serpapi"))
    }

    @Test func noKeyNoPackage() {
        let (store, defaults, root) = temp()
        defer { try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        PackageMigration.run(store: store, defaults: defaults, readKey: { _ in nil }, deleteKey: { _ in })
        #expect(store.installed.isEmpty)
        #expect(defaults.bool(forKey: PackageMigration.doneKey))
    }

    @Test func limitsStopASourceForTheMonth() {
        let id = "test-quota-\(UUID().uuidString.prefix(6).lowercased())"
        let limits = PackageLimits(daily: nil, monthly: 960)
        for _ in 0..<950 { SearchQuota.record(id) }
        var allowed = 0
        while SearchQuota.canUse(id, limits: limits) { SearchQuota.record(id); allowed += 1 }
        #expect(allowed == 10)
        #expect(SearchQuota.canUse(id, limits: nil), "no limits, no cap")
    }
}
