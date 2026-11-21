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
        return list.prefix(10).compactMap { item -> WebSourcesProvider.Hit? in
            guard let title = item["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            // A web page, or a file on this Mac (a note).
            let url = item["url"].flatMap(URL.init(string:)).flatMap { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let snippet = item["snippet"].map { String($0.prefix(500)) }
            return WebSourcesProvider.Hit(title: String(title.prefix(200)), url: url, source: entry.package.name,
                                          snippet: snippet?.isEmpty == false ? snippet : nil)
        }
    }

    /// The Test button: runs the command's test query and says what came back.
    static func test(_ entry: PackageRegistry.Entry, _ command: PackageCommand) async -> Result<[WebSourcesProvider.Hit], Error> {
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
