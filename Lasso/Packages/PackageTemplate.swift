import Foundation

/// `{{name}}` templates in a package's requests. Values are escaped for where they land (spec,
/// "Templates and responses"); there are no expressions, conditions or loops.
enum PackageTemplate {
    enum Context { case urlPath, urlQuery, raw }

    struct HeaderLineBreak: Error {}

    /// The names a template uses, in order.
    static func names(in template: String) -> [String] {
        template.matches(of: #/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/#).map { String($0.1) }
    }

    /// `template` with each `{{name}}` replaced by `values[name]` (missing → empty), escaped for `context`.
    static func render(_ template: String, _ values: [String: String], _ context: Context) -> String {
        template.replacing(#/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/#) { match in
            let value = values[String(match.1)] ?? ""
            switch context {
            case .urlPath: return value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? ""
            case .urlQuery: return value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
            case .raw: return value
            }
        }
    }

    /// A URL template: the part before `?` is a path (a value can't add segments), the part after a query.
    static func renderURL(_ template: String, _ values: [String: String]) -> String {
        // A server setting's base URL starts the template: it's inserted as is (validated as a URL).
        var head = "", rest = template
        if let match = template.firstMatch(of: #/^\{\{settings\.([a-z0-9_]+)\}\}/#) {
            var base = values["settings.\(match.1)"] ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            head = base
            rest = String(template[match.range.upperBound...])
        }
        guard let mark = rest.firstIndex(of: "?") else { return head + render(rest, values, .urlPath) }
        return head + render(String(rest[..<mark]), values, .urlPath) + "?" + render(String(rest[rest.index(after: mark)...]), values, .urlQuery)
    }

    /// A header value; a line break in it is refused (it could start another header).
    static func renderHeader(_ template: String, _ values: [String: String]) throws -> String {
        let value = render(template, values, .raw)
        // By scalar: "\r\n" is one Character in Swift, equal to neither "\r" nor "\n".
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { throw HeaderLineBreak() }
        return value
    }

    /// A JSON body: string leaves rendered unescaped, then serialized (which escapes them for JSON).
    static func renderJSON(_ value: PackageJSON, _ values: [String: String]) -> Any {
        switch value {
        case .string(let s): render(s, values, .raw)
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map { renderJSON($0, values) }
        case .object(let o): o.mapValues { renderJSON($0, values) }
        }
    }

    /// `application/x-www-form-urlencoded`.
    static func formEncode(_ pairs: [String: String]) -> String {
        pairs.keys.sorted().map { key in
            let k = key.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
            let v = (pairs[key] ?? "").addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// Unreserved characters only: `&`, `=`, `+`, `#`, `/`, `?` and spaces are all encoded.
    static let queryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let pathSegmentAllowed = queryValueAllowed
}
