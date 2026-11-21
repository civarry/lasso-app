import Foundation
import Observation

/// The package catalog (`civarry/lasso-packages`, spec "The catalog"): its `index.json`, read only when
/// the user opens Browse or checks for package updates, never in local-only mode. A download whose
/// SHA-256 isn't the one in the index is refused.
@MainActor
@Observable
final class PackageCatalog {
    static let shared = PackageCatalog()

    nonisolated static let indexURL = URL(string: "https://raw.githubusercontent.com/civarry/lasso-packages/main/index.json")!
    nonisolated static let host = "raw.githubusercontent.com"

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String
        var version: String
        var name: String
        var summary: String
        var author: String
        var category: String?
        var minLasso: String?
        var symbol: String?
        var domain: String?
        var url: URL
        var sha256: String
        /// Short tags for the list: "Needs a key", "Runs code", "Changes Lasso".
        var tags: [String]
        var surfaces: [String]
    }

    enum LoadError: LocalizedError, Equatable {
        case localOnly
        case unreachable(String)
        case unreadable
        case hashMismatch
        case notAPackage

        var errorDescription: String? {
            switch self {
            case .localOnly: "The catalog is off in local-only mode."
            case .unreachable(let why): "Couldn't reach the catalog: \(why)"
            case .unreadable: "The catalog's list couldn't be read."
            case .hashMismatch: "The download doesn't match the catalog, so Lasso didn't use it."
            case .notAPackage: "The download isn't a Lasso package."
            }
        }
    }

    enum State: Equatable { case idle, loading, loaded, failed(String) }

    /// Settable for snapshot tests; otherwise only `refresh` changes it.
    var entries: [Entry] = []
    var state: State = .idle
    var checked: Date?
    /// A `lasso://install?id=` link's package, until Browse shows it.
    var requested: String?

    private let session: URLSession
    private let indexURL: URL

    init(session: URLSession = .shared, indexURL: URL = PackageCatalog.indexURL) {
        self.session = session
        self.indexURL = indexURL
    }

    /// Whether Browse should read the index again (not read yet, or over 5 minutes ago).
    var isStale: Bool { checked.map { Date().timeIntervalSince($0) > 300 } ?? true }

    /// Reads the index (the user opened Browse, or chose Check for Updates).
    func refresh(localOnly: Bool = PrivacyMode.localOnly) async {
        guard !localOnly else { state = .failed(LoadError.localOnly.localizedDescription); return }
        state = .loading
        do {
            var request = URLRequest(url: indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Lasso/\(Bundle.main.lassoVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LoadError.unreachable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            entries = try Self.parse(data)
            checked = Date()
            state = .loaded
        } catch let error as LoadError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed(LoadError.unreachable(error.localizedDescription).localizedDescription)
        }
    }

    nonisolated static func parse(_ data: Data) throws -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["lasso"] as? Int == 1, let list = root["packages"] as? [[String: Any]] else { throw LoadError.unreadable }
        return list.compactMap { o -> Entry? in
            guard let id = o["id"] as? String, PackageValidator.matches(id, PackageValidator.idPattern),
                  let version = o["version"] as? String, let name = o["name"] as? String,
                  let link = (o["url"] as? String).flatMap(URL.init(string:)), link.scheme == "https",
                  link.host == host, let sha = o["sha256"] as? String else { return nil }
            let permissions = o["permissions"] as? [String: Any] ?? [:]
            var tags: [String] = []
            if permissions["key"] as? Bool == true { tags.append("Needs a key") }
            if permissions["script"] as? Bool == true { tags.append("Runs code") }
            if permissions["shortcut"] as? Bool == true { tags.append("Uses a Shortcut") }
            if permissions["patches"] as? Bool == true { tags.append("Changes Lasso") }
            if permissions["model"] as? Bool == true { tags.append("Uses your model") }
            // Only when nothing in it can send anything anywhere (a model may be in the cloud).
            if (permissions["hosts"] as? [String] ?? []).isEmpty, permissions["network"] as? Bool != true,
               permissions["model"] as? Bool != true, permissions["shortcut"] as? Bool != true { tags.append("Stays on your Mac") }
            let surfaces = (o["commands"] as? [[String: Any]] ?? []).flatMap { $0["surfaces"] as? [String] ?? [] }
            return Entry(id: id, version: version, name: name, summary: o["summary"] as? String ?? "",
                         author: o["author"] as? String ?? "", category: o["category"] as? String,
                         minLasso: o["minLasso"] as? String, symbol: o["symbol"] as? String, domain: o["domain"] as? String,
                         url: link, sha256: sha.lowercased(), tags: tags, surfaces: Array(Set(surfaces)).sorted())
        }
    }

    /// Downloads a package and checks it against the index; the review comes next, and only the user's
    /// click there installs it.
    func download(_ entry: Entry, localOnly: Bool = PrivacyMode.localOnly) async throws -> (manifest: Data, files: PackageFiles.Files) {
        guard !localOnly else { throw LoadError.localOnly }
        guard entry.url.host == Self.host else { throw LoadError.notAPackage }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(from: entry.url) } catch { throw LoadError.unreachable(error.localizedDescription) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LoadError.unreachable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try Self.verify(data, entry)
    }

    nonisolated static func verify(_ data: Data, _ entry: Entry) throws -> (manifest: Data, files: PackageFiles.Files) {
        guard PackageFiles.sha256(data) == entry.sha256 else { throw LoadError.hashMismatch }
        guard let unpacked = PackageBundle.unpack(data) else { throw LoadError.notAPackage }
        return unpacked
    }

    /// Installed packages the catalog has a newer version of.
    func updates(_ installed: [PackageStore.Installed]) -> [(installed: PackageStore.Installed, entry: Entry)] {
        // A package you're developing isn't the catalog's to update.
        installed.filter { $0.origin != .developer }.compactMap { item in
            guard let entry = entries.first(where: { $0.id == item.id }),
                  PackageValidator.isNewer(entry.version, than: item.package.version) else { return nil }
            return (item, entry)
        }
    }

    /// Whether this Lasso can run it (`minLasso`).
    func isTooNew(_ entry: Entry) -> Bool {
        entry.minLasso.map { PackageValidator.isNewer($0, than: Bundle.main.lassoVersion) } ?? false
    }
}
