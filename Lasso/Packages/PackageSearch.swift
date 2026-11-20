import Foundation

/// A search package's command, run for one query. Failures are skipped quietly (spec: "skipped
/// silently in a background search") and logged without secrets.
enum PackageSearch {
    static func run(_ entry: PackageRegistry.Entry, _ command: PackageCommand, query: String) async -> [WebSourcesProvider.Hit] {
        let package = entry.package
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

    /// The Test button: runs the command's test query and says what came back.
    static func test(_ entry: PackageRegistry.Entry, _ command: PackageCommand) async -> Result<[WebSourcesProvider.Hit], Error> {
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
