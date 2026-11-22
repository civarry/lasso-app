import Foundation

/// A search package's command, run for one query. Failures are skipped quietly (spec: "skipped
/// silently in a background search") and logged without secrets.
enum PackageSearch {
    static func run(_ entry: PackageRegistry.Entry, _ command: PackageCommand, query: String) async -> [WebSourcesProvider.Hit] {
        let package = entry.package
        if command.script != nil {
            do { return try await script(entry, command, query: query) } catch {
                let reason = PackageHTTP.redact(error.localizedDescription, secrets: entry.secrets)
                Log.chat.error("package \(package.id, privacy: .public) · didn't work: \(reason, privacy: .public)")
                return []
            }
        }
        guard let http = command.http, let map = http.results else { return [] }
        guard SearchQuota.canUse(package.id, limits: package.limits) else {
            Log.chat.notice("package \(package.id, privacy: .public) · skipped: its limit is reached")
            return []
        }
        var values = entry.values
        values["query"] = query
        values["language"] = Locale.current.language.languageCode?.identifier ?? "en"
        let started = Date()
        do {
            let request = try PackageHTTP.request(http, values: values)
            let json = try await PackageHTTP.send(request, allowed: PackageHTTP.allowedHosts(package, values: entry.values))
            SearchQuota.record(package.id)
            let hits = PackageHTTP.results(json, map: map, source: package.name)
            Log.chat.notice("package \(package.id, privacy: .public) · \(hits.count, privacy: .public) results in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
            return hits
        } catch {
            let reason = PackageHTTP.redact(error.localizedDescription, secrets: entry.secrets)
            Log.chat.error("package \(package.id, privacy: .public) · didn't work: \(reason, privacy: .public)")
            return []
        }
    }

    /// A script as a search source: it answers `{"results": [{"title", "url", "snippet"}]}`, at most 10.
    static func script(_ entry: PackageRegistry.Entry, _ command: PackageCommand, query: String) async throws -> [WebSourcesProvider.Hit] {
        guard let run = command.script else { return [] }
        guard let places = entry.places else { throw PackageScript.RunError.missing(run.path) }
        let request = PackageScript.Request(command: command.id, stdin: PackageScript.stdin(entry, command, input: PackageInput(), query: query),
                                            secrets: PackageScript.secrets(entry), run: run, unsandboxed: entry.fullAccess)
        guard case .results(let list) = try await PackageScript.run(request, places: places) else {
            throw PackageScript.RunError.badOutput("a search script answers {\"results\": [...]}.")
        }
        return hits(list, entry: entry)
    }

    /// A `source/1` command: the whole turn in (docs/PACKAGE-HOOKS.md), a status and results out. Lasso
    /// applies the gate (unless it ranks its own), the budget, fencing and consent afterwards.
    static func source(_ entry: PackageRegistry.Entry, _ command: PackageCommand, turn: SourceTurn) async throws -> SourceAnswer {
        guard let run = command.script else { return SourceAnswer(status: .nothing, hits: []) }
        guard let places = entry.places else { throw PackageScript.RunError.missing(run.path) }
        let stdin = PackageScript.stdin(entry, command, input: PackageInput(), query: turn.query, extra: turn.fields())
        let request = PackageScript.Request(command: command.id, stdin: stdin, secrets: PackageScript.secrets(entry),
                                            run: run, unsandboxed: entry.fullAccess)
        let reply: PackageScript.SourceReply
        switch try await PackageScript.run(request, places: places) {
        case .source(let answer): reply = answer
        case .results(let list): reply = .init(status: list.isEmpty ? .nothing : .found, results: list)
        default: throw PackageScript.RunError.badOutput("a source/1 script answers {\"status\": ..., \"results\": [...]}.")
        }
        return SourceAnswer(status: reply.status, hits: hits(reply.results, entry: entry).map {
            SourceHit(source: entry.package.name, title: $0.title, url: $0.url, snippet: $0.snippet ?? "")
        }, searched: reply.searched, ask: reply.ask, note: reply.note)
    }

    /// A script's results as hits: at most 10, a web page or a file on this Mac.
    static func hits(_ list: [[String: String]], entry: PackageRegistry.Entry) -> [WebSourcesProvider.Hit] {
        list.prefix(10).compactMap { item -> WebSourcesProvider.Hit? in
            guard let title = item["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let url = item["url"].flatMap(URL.init(string:)).flatMap { url -> URL? in
                switch url.scheme?.lowercased() {
                case "http", "https": return url
                case "file": return openableFile(url, entry: entry) ? url : nil
                default: return nil
                }
            }
            var snippet = item["snippet"].map { String($0.prefix(500)) }
            if let date = item["date"], !date.isEmpty, let text = snippet { snippet = "[\(date.prefix(10))] " + text }
            return WebSourcesProvider.Hit(title: String(title.prefix(200)), url: url, source: entry.package.name,
                                          snippet: snippet?.isEmpty == false ? snippet : nil)
        }
    }

    /// A file a result may link to: one in a folder the user picked for this package (their notes),
    /// and not a program. A script can write files in its own folders, so a link to one of those (a
    /// `.command` it made) would run it outside the sandbox with a click.
    static func openableFile(_ url: URL, entry: PackageRegistry.Entry) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        guard let folders = entry.places?.folders, !folders.isEmpty,
              folders.contains(where: { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else { return false }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return false }
        if fm.isExecutableFile(atPath: path) { return false }
        let programs: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "pkg", "mpkg", "terminal",
                                     "workflow", "scpt", "applescript", "jar", "dmg", "webloc", "inetloc", "fileloc"]
        return !programs.contains(url.pathExtension.lowercased())
    }

    /// A `describe/1` command: the What's in it line and picking words.
    static func describe(_ entry: PackageRegistry.Entry, _ command: PackageCommand) async throws -> (about: String, words: [String]) {
        guard let run = command.script, let places = entry.places else { throw PackageScript.RunError.missing(command.script?.path ?? "") }
        let stdin = PackageScript.stdin(entry, command, input: PackageInput(), extra: ["hook": "describe/1"])
        let request = PackageScript.Request(command: command.id, stdin: stdin, secrets: PackageScript.secrets(entry),
                                            run: run, unsandboxed: entry.fullAccess)
        guard case .describe(let about, let words) = try await PackageScript.run(request, places: places) else {
            throw PackageScript.RunError.badOutput("a describe/1 script answers {\"about\": ..., \"words\": [...]}.")
        }
        return (about, words)
    }

    /// The Test button: runs the command's test query and says what came back.
    static func test(_ entry: PackageRegistry.Entry, _ command: PackageCommand) async -> Result<[WebSourcesProvider.Hit], Error> {
        if command.hook == .source {
            let q = command.testQuery ?? "lasso"
            do {
                let answer = try await source(entry, command, turn: SourceTurn(message: q, query: q))
                return .success(answer.hits.map { WebSourcesProvider.Hit(title: $0.title, url: $0.url, source: entry.package.name, snippet: $0.snippet) })
            } catch { return .failure(error) }
        }
        if command.script != nil {
            do { return .success(try await script(entry, command, query: command.testQuery ?? "lasso")) } catch { return .failure(error) }
        }
        guard let http = command.http, let map = http.results else { return .success([]) }
        // A test is a real search: it counts, and it respects the limit.
        guard SearchQuota.canUse(entry.package.id, limits: entry.package.limits) else {
            return .failure(PackageHTTP.RunError.failed("Limit reached."))
        }
        var values = entry.values
        values["query"] = command.testQuery ?? "lasso"
        values["language"] = Locale.current.language.languageCode?.identifier ?? "en"
        do {
            let request = try PackageHTTP.request(http, values: values)
            let json = try await PackageHTTP.send(request, allowed: PackageHTTP.allowedHosts(entry.package, values: entry.values))
            SearchQuota.record(entry.package.id)
            return .success(PackageHTTP.results(json, map: map, source: entry.package.name))
        } catch {
            return .failure(error)
        }
    }
}
