import Foundation

/// Runs a package's `http` command. The package only describes the request; Lasso makes it, to the
/// package's declared hosts only (redirects included), with no cookies or shared state, and never off
/// the Mac in local-only mode.
enum PackageHTTP {
    static let maxResponseBytes = 2 * 1024 * 1024

    enum RunError: LocalizedError, Equatable {
        case localOnly
        case undeclaredHost(String)
        case headerLineBreak(String)
        case badURL
        case status(Int)
        case tooLarge
        case notJSON
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .localOnly: "Paused in local-only mode."
            case .undeclaredHost(let h): "It tried to reach \(h), which it didn't declare."
            case .headerLineBreak(let h): "The \(h) header had a line break in it."
            case .badURL: "Its address didn't make a valid URL."
            case .status(let code): code == 401 || code == 403 ? "The service refused the key (\(code))." : "The service answered \(code)."
            case .tooLarge: "The answer was over 2 MB."
            case .notJSON: "The answer wasn't JSON."
            case .failed(let reason): reason
            }
        }
    }

    /// The hosts a package may reach: its `hosts`, plus the host of each `server` setting's value.
    static func allowedHosts(_ package: LassoPackage, values: [String: String]) -> Set<String> {
        var hosts = Set(package.hosts)
        for setting in package.settings where setting.kind == .server {
            if let host = URL(string: values["settings.\(setting.id)"] ?? "")?.host?.lowercased() { hosts.insert(host) }
        }
        return hosts
    }

    /// The request a command makes with `values` (inputs, settings and `language`).
    static func request(_ run: PackageHTTPRun, values: [String: String]) throws -> URLRequest {
        var text = PackageTemplate.renderURL(run.url, values)
        if !run.query.isEmpty {
            let extra = run.query.keys.sorted().map { key in
                let k = key.addingPercentEncoding(withAllowedCharacters: PackageTemplate.queryValueAllowed) ?? ""
                return "\(k)=\(PackageTemplate.render(run.query[key] ?? "", values, .urlQuery))"
            }.joined(separator: "&")
            text += (text.contains("?") ? "&" : "?") + extra
        }
        guard let url = URL(string: text), url.host != nil else { throw RunError.badURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: run.timeout)
        request.httpMethod = run.method
        request.httpShouldHandleCookies = false
        for (name, template) in run.headers.sorted(by: { $0.key < $1.key }) {
            do { request.setValue(try PackageTemplate.renderHeader(template, values), forHTTPHeaderField: name) }
            catch { throw RunError.headerLineBreak(name) }
        }
        request.setValue("Lasso/\(Bundle.main.lassoVersion)", forHTTPHeaderField: "User-Agent")
        if let json = run.json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: PackageTemplate.renderJSON(json, values),
                                                           options: [.sortedKeys, .withoutEscapingSlashes])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form = run.form {
            let rendered = form.mapValues { PackageTemplate.render($0, values, .raw) }
            request.httpBody = Data(PackageTemplate.formEncode(rendered).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends `request` and returns the JSON answer. Refuses an undeclared host before connecting and
    /// doesn't follow a redirect to one.
    static func send(_ request: URLRequest, allowed: Set<String>, localOnly: Bool = PrivacyMode.localOnly) async throws -> Any {
        guard let host = request.url?.host?.lowercased() else { throw RunError.badURL }
        guard allowed.contains(host) else { throw RunError.undeclaredHost(host) }
        if localOnly, !PackageValidator.isLoopback(host) { throw RunError.localOnly }

        let guardDelegate = RedirectGuard(allowed: allowed, localOnly: localOnly)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate) }
        catch { throw RunError.failed(error.localizedDescription) }
        if let refused = guardDelegate.refusedHost { throw RunError.undeclaredHost(refused) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RunError.status(status) }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxResponseBytes { throw RunError.tooLarge }
            }
        } catch let error as RunError { throw error } catch { throw RunError.failed(error.localizedDescription) }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw RunError.notJSON }
        return json
    }

    /// No cookies, no cache, nothing shared with Lasso's other requests or between packages.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let allowed: Set<String>
        let localOnly: Bool
        private let lock = NSLock()
        private var refused: String?
        var refusedHost: String? { lock.withLock { refused } }

        init(allowed: Set<String>, localOnly: Bool) { self.allowed = allowed; self.localOnly = localOnly }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            let host = request.url?.host?.lowercased() ?? ""
            let ok = allowed.contains(host) && (!localOnly || PackageValidator.isLoopback(host))
                && (request.url?.scheme == "https" || PackageValidator.isLoopback(host))
            if !ok { lock.withLock { refused = host } }
            return ok ? request : nil
        }
    }

    // MARK: Responses

    /// A dot path into JSON: keys and array indexes (`web.results`, `data.0.text`). Missing → nil.
    static func value(_ json: Any, at path: String) -> Any? {
        guard !path.isEmpty else { return json }
        var current: Any? = json
        for part in path.split(separator: ".") {
            if let object = current as? [String: Any] { current = object[String(part)] }
            else if let array = current as? [Any], let i = Int(part), array.indices.contains(i) { current = array[i] }
            else { return nil }
        }
        return current
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: plain(s)
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    /// Services put HTML in their text (Wikipedia marks matches with <span>): tags out, common entities
    /// decoded, whitespace collapsed. It's shown as plain text and given to models as content.
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<[^>]{0,200}>", with: "", options: .regularExpression)
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Search results, trimmed (titles 200 characters, snippets 500) and labelled with the package.
    static func results(_ json: Any, map: PackageHTTPRun.ResultsMap, source: String) -> [WebSourcesProvider.Hit] {
        guard let list = value(json, at: map.list) as? [Any] else { return [] }
        return list.prefix(map.limit).compactMap { item in
            guard let title = text(value(item, at: map.title))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let url = map.url.flatMap { text(value(item, at: $0)) }.flatMap(URL.init(string:))
                .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let snippet = map.snippet.flatMap { text(value(item, at: $0)) }.map { String($0.prefix(500)) }
            return WebSourcesProvider.Hit(title: String(title.prefix(200)), url: url, source: source,
                                          snippet: snippet?.isEmpty == false ? snippet : nil)
        }
    }

    /// `text` with every secret replaced by •••, for anything logged or shown.
    static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        for secret in secrets where secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: "•••")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: PackageTemplate.queryValueAllowed), encoded != secret {
                out = out.replacingOccurrences(of: encoded, with: "•••")
            }
        }
        return out
    }
}
