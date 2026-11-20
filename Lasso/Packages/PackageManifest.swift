import Foundation

/// A Lasso package as installed: its manifest, read and checked against `docs/PACKAGES.md` (format
/// version 1). Everything a package can do is in here as data; nothing in it runs by itself.
struct LassoPackage: Sendable, Equatable {
    var id: String
    var version: String
    var name: String
    var summary: String
    var author: String
    var homepage: URL?
    var iconSymbol: String?
    var iconDomain: String?
    var category: String?
    var hosts: [String]
    var settings: [PackageSetting]
    var limits: PackageLimits?
    var minLasso: String?
    var commands: [PackageCommand]

    func setting(_ id: String) -> PackageSetting? { settings.first { $0.id == id } }
    func command(_ id: String) -> PackageCommand? { commands.first { $0.id == id } }
}

struct PackageLimits: Sendable, Equatable {
    var daily: Int?
    var monthly: Int?
}

struct PackageSetting: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable { case secret, text, choice, toggle, server, folder }
    var id: String
    var label: String
    var kind: Kind
    var help: URL?
    var options: [String] = []
    var defaultValue: String?
}

struct PackageCommand: Sendable, Equatable {
    enum Surface: String, Sendable, CaseIterable { case toolbar, send, slash, tool, search, hotkey }
    enum Input: String, Sendable, CaseIterable { case text, image, source, query, args }
    enum Output: String, Sendable, CaseIterable { case markdown, copy, replace, open, image, file, notify, results }

    var id: String
    var title: String
    var symbol: String?
    var surfaces: [Surface]
    var input: [Input]
    var output: Output
    var run: PackageHTTPRun
    var testQuery: String?
}

/// The `http` runner, as declared. Values are templates (`{{query}}`, `{{settings.key}}`).
struct PackageHTTPRun: Sendable, Equatable {
    enum Role: String, Sendable { case primary, reserve }
    var method: String
    var url: String
    var query: [String: String]
    var headers: [String: String]
    var json: PackageJSON?
    var form: [String: String]?
    var timeout: Double
    var results: ResultsMap?
    var answer: String?
    var role: Role

    struct ResultsMap: Sendable, Equatable {
        var list: String
        var title: String
        var url: String?
        var snippet: String?
        var limit: Int
    }
}

/// A JSON value from a manifest (a request body), kept as a tree so string leaves can be templates.
indirect enum PackageJSON: Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([PackageJSON]), object([String: PackageJSON])

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(PackageJSON.init))
        case let o as [String: Any]: self = .object(o.mapValues(PackageJSON.init))
        default: self = .null
        }
    }

    /// Every string leaf, for template checks.
    var strings: [String] {
        switch self {
        case .string(let s): [s]
        case .array(let a): a.flatMap(\.strings)
        case .object(let o): o.values.flatMap(\.strings)
        default: []
        }
    }
}

/// One thing wrong with a package, at the field it's in ("commands[0].run.http.url").
struct PackageProblem: Sendable, Equatable, CustomStringConvertible {
    var path: String
    var message: String
    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// Reads a manifest and checks every rule; returns the package or every problem found.
enum PackageValidator {
    /// The newest package format this Lasso reads.
    static let formatVersion = 1
    static let maxManifestBytes = 64 * 1024

    enum Outcome: Sendable {
        case valid(LassoPackage)
        case invalid([PackageProblem])

        var package: LassoPackage? { if case .valid(let p) = self { p } else { nil } }
        var problems: [PackageProblem] { if case .invalid(let p) = self { p } else { [] } }
    }

    static func validate(_ data: Data, lassoVersion: String = Bundle.main.lassoVersion) -> Outcome {
        guard data.count <= maxManifestBytes else {
            return .invalid([PackageProblem(path: "", message: "The manifest is over 64 KB.")])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return .invalid([PackageProblem(path: "", message: "This isn't a package: it must be a JSON object.")])
        }
        var reader = Reader(lassoVersion: lassoVersion)
        let package = reader.package(root)
        if let package, reader.problems.isEmpty { return .valid(package) }
        return .invalid(reader.problems.isEmpty ? [PackageProblem(path: "", message: "Invalid package.")] : reader.problems)
    }

    // MARK: Patterns

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }
    static let idPattern = "[a-z][a-z0-9-]{2,39}"
    static let commandIDPattern = "[a-z0-9-]+"
    static let settingIDPattern = "[a-z][a-z0-9_]{0,39}"
    static let semverPattern = "[0-9]+\\.[0-9]+\\.[0-9]+"
    static let hostPattern = "[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+"
    static let categories: Set<String> = ["search", "knowledge", "productivity", "writing", "developer", "media", "fun"]
    static let forbiddenHeaders: Set<String> = ["host", "content-length", "cookie", "connection"]

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// `1.2.10` > `1.2.9`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Walks the manifest, collecting problems with their paths.
private struct Reader {
    let lassoVersion: String
    var problems: [PackageProblem] = []

    mutating func problem(_ path: String, _ message: String) {
        problems.append(PackageProblem(path: path, message: message))
    }

    /// Unknown fields are refused by name, so a typo is an error rather than a silent no-op.
    mutating func onlyKnown(_ object: [String: Any], _ known: Set<String>, at path: String) {
        for key in object.keys.sorted() where !known.contains(key) {
            problem(join(path, key), "Unknown field \"\(key)\".")
        }
    }

    func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    mutating func string(_ object: [String: Any], _ key: String, at path: String, required: Bool = true,
                         length: ClosedRange<Int>? = nil) -> String? {
        guard let value = object[key] else {
            if required { problem(join(path, key), "Required.") }
            return nil
        }
        guard let text = value as? String else { problem(join(path, key), "Must be text."); return nil }
        if let length, !length.contains(text.count) {
            problem(join(path, key), "Must be \(length.lowerBound) to \(length.upperBound) characters.")
        }
        return text
    }

    mutating func int(_ object: [String: Any], _ key: String, at path: String, range: ClosedRange<Int>) -> Int? {
        guard let value = object[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else {
            problem(join(path, key), "Must be a whole number."); return nil
        }
        guard range.contains(number.intValue) else {
            problem(join(path, key), "Must be \(range.lowerBound) to \(range.upperBound)."); return nil
        }
        return number.intValue
    }

    mutating func stringMap(_ object: [String: Any], _ key: String, at path: String) -> [String: String]? {
        guard let value = object[key] else { return nil }
        guard let map = value as? [String: Any] else { problem(join(path, key), "Must be an object."); return nil }
        var out: [String: String] = [:]
        for (k, v) in map {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { out[k] = n.stringValue }
            else { problem(join(join(path, key), k), "Must be text.") }
        }
        return out
    }

    // MARK: Package

    mutating func package(_ root: [String: Any]) -> LassoPackage? {
        // `$schema` is for editors (docs/packages/schema-v1.json); Lasso doesn't read it.
        onlyKnown(root, ["$schema", "lasso", "id", "version", "name", "summary", "author", "homepage", "icon", "category",
                         "hosts", "settings", "requires", "limits", "minLasso", "commands", "patches"], at: "")
        guard let format = root["lasso"] as? Int else {
            problem("lasso", root["lasso"] == nil ? "Required: the format version, 1." : "Must be a whole number.")
            return nil
        }
        if format > PackageValidator.formatVersion {
            problem("lasso", "Needs a newer Lasso (this package uses format \(format)).")
            return nil
        }
        if format < 1 { problem("lasso", "Must be 1.") }

        let id = string(root, "id", at: "") ?? ""
        if !id.isEmpty, !PackageValidator.matches(id, PackageValidator.idPattern) {
            problem("id", "3 to 40 characters: lowercase letters, digits and \"-\", starting with a letter.")
        }
        let version = string(root, "version", at: "") ?? ""
        if !version.isEmpty, !PackageValidator.matches(version, PackageValidator.semverPattern) {
            problem("version", "Must be MAJOR.MINOR.PATCH, like 1.0.0.")
        }
        let name = string(root, "name", at: "", length: 1...40) ?? ""
        let summary = string(root, "summary", at: "", length: 1...120) ?? ""
        let author = string(root, "author", at: "", length: 1...80) ?? ""
        var homepage: URL?
        if let page = string(root, "homepage", at: "", required: false) {
            homepage = URL(string: page)
            if homepage?.scheme != "https" || homepage?.host == nil { problem("homepage", "Must be an https link.") }
        }

        var iconSymbol: String?, iconDomain: String?
        if let icon = root["icon"] {
            if let icon = icon as? [String: Any] {
                onlyKnown(icon, ["symbol", "domain"], at: "icon")
                iconSymbol = string(icon, "symbol", at: "icon", required: false, length: 1...80)
                iconDomain = string(icon, "domain", at: "icon", required: false)
                if let d = iconDomain, !PackageValidator.matches(d, PackageValidator.hostPattern) {
                    problem("icon.domain", "Must be a domain, like example.com.")
                }
            } else { problem("icon", "Must be an object with symbol and/or domain.") }
        }

        let category = string(root, "category", at: "", required: false)
        if let category, !PackageValidator.categories.contains(category) {
            problem("category", "Must be one of: \(PackageValidator.categories.sorted().joined(separator: ", ")).")
        }

        var hosts: [String] = []
        if let raw = root["hosts"] {
            if let list = raw as? [Any] {
                for (i, item) in list.enumerated() {
                    guard let host = item as? String,
                          PackageValidator.matches(host, PackageValidator.hostPattern) else {
                        problem("hosts[\(i)]", "Must be a host name like api.example.com: no wildcards, ports or paths.")
                        continue
                    }
                    hosts.append(host.lowercased())
                }
            } else { problem("hosts", "Must be a list of host names.") }
        }

        let settings = self.settings(root["settings"])
        var limits: PackageLimits?
        if let raw = root["limits"] {
            if let l = raw as? [String: Any] {
                onlyKnown(l, ["daily", "monthly"], at: "limits")
                limits = PackageLimits(daily: int(l, "daily", at: "limits", range: 1...1_000_000),
                                       monthly: int(l, "monthly", at: "limits", range: 1...10_000_000))
            } else { problem("limits", "Must be an object with daily and/or monthly.") }
        }
        let minLasso = string(root, "minLasso", at: "", required: false)
        if let minLasso {
            if !PackageValidator.matches(minLasso, PackageValidator.semverPattern) {
                problem("minLasso", "Must be a version like 0.17.0.")
            } else if PackageValidator.isNewer(minLasso, than: lassoVersion) {
                problem("minLasso", "Needs Lasso \(minLasso) or newer (this is \(lassoVersion)).")
            }
        }
        if root["requires"] != nil { problem("requires", "This version of Lasso can't run scripts yet.") }
        if root["patches"] != nil { problem("patches", "This version of Lasso can't apply patches yet.") }

        var commands: [PackageCommand] = []
        if let raw = root["commands"] {
            if let list = raw as? [Any], (1...12).contains(list.count) {
                var seen = Set<String>()
                for (i, item) in list.enumerated() {
                    let path = "commands[\(i)]"
                    guard let object = item as? [String: Any] else { problem(path, "Must be an object."); continue }
                    if let command = self.command(object, at: path, hosts: hosts, settings: settings) {
                        if !seen.insert(command.id).inserted { problem(join(path, "id"), "Another command has this id.") }
                        commands.append(command)
                    }
                }
            } else { problem("commands", "Must be a list of 1 to 12 commands.") }
        } else if root["patches"] == nil {
            problem("commands", "Required: a package needs commands (or patches).")
        }

        return LassoPackage(id: id, version: version, name: name, summary: summary, author: author,
                            homepage: homepage, iconSymbol: iconSymbol, iconDomain: iconDomain, category: category,
                            hosts: hosts, settings: settings, limits: limits, minLasso: minLasso, commands: commands)
    }

    // MARK: Settings

    mutating func settings(_ raw: Any?) -> [PackageSetting] {
        guard let raw else { return [] }
        guard let list = raw as? [Any], list.count <= 8 else { problem("settings", "Must be a list of at most 8 settings."); return [] }
        var out: [PackageSetting] = []
        var seen = Set<String>()
        for (i, item) in list.enumerated() {
            let path = "settings[\(i)]"
            guard let o = item as? [String: Any] else { problem(path, "Must be an object."); continue }
            onlyKnown(o, ["id", "label", "kind", "help", "options", "default"], at: path)
            let id = string(o, "id", at: path) ?? ""
            if !id.isEmpty, !PackageValidator.matches(id, PackageValidator.settingIDPattern) {
                problem(join(path, "id"), "Lowercase letters, digits and \"_\", starting with a letter.")
            }
            if !seen.insert(id).inserted { problem(join(path, "id"), "Another setting has this id.") }
            let label = string(o, "label", at: path, length: 1...40) ?? ""
            let kindName = string(o, "kind", at: path) ?? ""
            let kind = PackageSetting.Kind(rawValue: kindName)
            if !kindName.isEmpty, kind == nil {
                problem(join(path, "kind"), "Must be one of: secret, text, choice, toggle, server, folder.")
            }
            if kind == .folder { problem(join(path, "kind"), "This version of Lasso can't use folder settings yet.") }
            var help: URL?
            if let h = string(o, "help", at: path, required: false) {
                help = URL(string: h)
                if help?.scheme != "https" { problem(join(path, "help"), "Must be an https link.") }
            }
            var options: [String] = []
            if kind == .choice {
                if let list = o["options"] as? [String], !list.isEmpty { options = list }
                else { problem(join(path, "options"), "A choice needs a list of options.") }
            } else if o["options"] != nil {
                problem(join(path, "options"), "Only a choice setting has options.")
            }
            var defaultValue: String?
            if let d = o["default"] {
                if kind == .secret { problem(join(path, "default"), "A secret can't have a default.") }
                else if let s = d as? String { defaultValue = s }
                else if let b = d as? Bool, kind == .toggle { defaultValue = b ? "true" : "false" }
                else { problem(join(path, "default"), "Must be text\(kind == .toggle ? " or true/false" : "").") }
                if kind == .choice, let dv = defaultValue, !options.contains(dv) {
                    problem(join(path, "default"), "Must be one of the options.")
                }
            }
            if let kind { out.append(PackageSetting(id: id, label: label, kind: kind, help: help, options: options, defaultValue: defaultValue)) }
        }
        return out
    }

    // MARK: Commands

    mutating func command(_ o: [String: Any], at path: String, hosts: [String], settings: [PackageSetting]) -> PackageCommand? {
        onlyKnown(o, ["id", "title", "symbol", "surfaces", "input", "when", "run", "output", "tool", "test"], at: path)
        let id = string(o, "id", at: path) ?? ""
        if !id.isEmpty, !PackageValidator.matches(id, PackageValidator.commandIDPattern) {
            problem(join(path, "id"), "Lowercase letters, digits and \"-\".")
        }
        let title = string(o, "title", at: path, length: 1...24) ?? ""
        let symbol = string(o, "symbol", at: path, required: false, length: 1...80)

        var surfaces: [PackageCommand.Surface] = []
        if let list = o["surfaces"] as? [String], !list.isEmpty {
            for (i, name) in list.enumerated() {
                guard let surface = PackageCommand.Surface(rawValue: name) else {
                    problem("\(path).surfaces[\(i)]", "Unknown surface \"\(name)\"."); continue
                }
                if surface != .search {
                    problem("\(path).surfaces[\(i)]", "This version of Lasso can't show commands on \"\(name)\" yet.")
                }
                surfaces.append(surface)
            }
        } else { problem(join(path, "surfaces"), "Required: a list of where the command appears.") }

        var inputs: [PackageCommand.Input] = []
        if let list = o["input"] as? [String] {
            for (i, name) in list.enumerated() {
                if let input = PackageCommand.Input(rawValue: name) { inputs.append(input) }
                else { problem("\(path).input[\(i)]", "Unknown input \"\(name)\".") }
            }
        } else if o["input"] != nil { problem(join(path, "input"), "Must be a list.") }

        let outputName = string(o, "output", at: path) ?? ""
        let output = PackageCommand.Output(rawValue: outputName)
        if !outputName.isEmpty, output == nil { problem(join(path, "output"), "Unknown output \"\(outputName)\".") }

        if o["when"] != nil { problem(join(path, "when"), "This version of Lasso can't use \"when\" yet.") }
        if o["tool"] != nil { problem(join(path, "tool"), "This version of Lasso can't offer commands as tools yet.") }

        if surfaces.contains(.search) {
            if inputs != [.query] { problem(join(path, "input"), "A search command takes [\"query\"].") }
            if output != .results { problem(join(path, "output"), "A search command's output is \"results\".") }
        }

        var testQuery: String?
        if let test = o["test"] {
            if let t = test as? [String: Any] {
                onlyKnown(t, ["text", "query", "args", "image"], at: join(path, "test"))
                testQuery = string(t, "query", at: join(path, "test"), required: false)
            } else { problem(join(path, "test"), "Must be an object.") }
        }
        if surfaces.contains(.search), testQuery?.isEmpty != false {
            problem(join(path, "test"), "A search command needs a test query, like {\"query\": \"lasso app\"}.")
        }

        guard let runObject = o["run"] as? [String: Any] else { problem(join(path, "run"), "Required."); return nil }
        let names = Set(inputs.map(\.rawValue)).union(["language"])
        guard let run = self.run(runObject, at: join(path, "run"), hosts: hosts, settings: settings,
                                 values: names, output: output) else { return nil }
        guard let output else { return nil }
        return PackageCommand(id: id, title: title, symbol: symbol, surfaces: surfaces, input: inputs,
                              output: output, run: run, testQuery: testQuery)
    }

    mutating func run(_ o: [String: Any], at path: String, hosts: [String], settings: [PackageSetting],
                      values: Set<String>, output: PackageCommand.Output?) -> PackageHTTPRun? {
        onlyKnown(o, ["http", "prompt", "system", "shortcut", "script", "results", "answer", "role"], at: path)
        for runner in ["prompt", "shortcut", "script"] where o[runner] != nil {
            problem(join(path, runner), "This version of Lasso can't run \"\(runner)\" commands yet.")
        }
        guard let http = o["http"] as? [String: Any] else {
            if o["prompt"] == nil, o["shortcut"] == nil, o["script"] == nil {
                problem(path, "Needs exactly one runner: http, prompt, shortcut or script.")
            }
            return nil
        }
        let hp = join(path, "http")
        onlyKnown(http, ["method", "url", "query", "headers", "json", "form", "timeout"], at: hp)
        let method = (string(http, "method", at: hp, required: false) ?? "GET").uppercased()
        if !["GET", "POST"].contains(method) { problem(join(hp, "method"), "Must be GET or POST.") }

        let url = string(http, "url", at: hp) ?? ""
        checkURL(url, at: join(hp, "url"), hosts: hosts, settings: settings)
        let query = stringMap(http, "query", at: hp) ?? [:]
        let headers = stringMap(http, "headers", at: hp) ?? [:]
        for name in headers.keys where PackageValidator.forbiddenHeaders.contains(name.lowercased()) {
            problem(join(join(hp, "headers"), name), "Lasso sets \(name) itself.")
        }
        var json: PackageJSON?
        if let body = http["json"] { json = PackageJSON(body) }
        let form = stringMap(http, "form", at: hp)
        if json != nil, form != nil { problem(hp, "Use json or form, not both.") }
        if (json != nil || form != nil), method == "GET" { problem(hp, "A body needs \"method\": \"POST\".") }
        var timeout = 8.0
        if let t = http["timeout"] {
            if let n = (t as? NSNumber)?.doubleValue, (1...20).contains(n) { timeout = n }
            else { problem(join(hp, "timeout"), "Must be 1 to 20 seconds.") }
        }

        // Templates may name only what this command has.
        let allowed = values.union(settings.map { "settings.\($0.id)" })
        var templated: [(String, String)] = [(join(hp, "url"), url)]
        templated += query.map { (join(join(hp, "query"), $0.key), $0.value) }
        templated += headers.map { (join(join(hp, "headers"), $0.key), $0.value) }
        templated += (form ?? [:]).map { (join(join(hp, "form"), $0.key), $0.value) }
        templated += (json?.strings ?? []).map { (join(hp, "json"), $0) }
        for (field, template) in templated {
            for name in PackageTemplate.names(in: template) where !allowed.contains(name) {
                problem(field, "Unknown value {{\(name)}}.")
            }
        }

        var results: PackageHTTPRun.ResultsMap?
        if let r = o["results"] {
            if let r = r as? [String: Any] {
                let rp = join(path, "results")
                onlyKnown(r, ["list", "title", "url", "snippet", "limit"], at: rp)
                let list = string(r, "list", at: rp) ?? ""
                let title = string(r, "title", at: rp) ?? ""
                results = .init(list: list, title: title, url: string(r, "url", at: rp, required: false),
                                snippet: string(r, "snippet", at: rp, required: false),
                                limit: int(r, "limit", at: rp, range: 1...10) ?? 10)
            } else { problem(join(path, "results"), "Must be an object.") }
        }
        if output == .results, results == nil { problem(join(path, "results"), "Required for \"results\" output: where the list and its titles are.") }
        if output != .results, results != nil { problem(join(path, "results"), "Only for \"results\" output.") }
        let answer = string(o, "answer", at: path, required: false)
        var role = PackageHTTPRun.Role.primary
        if let r = string(o, "role", at: path, required: false) {
            if let parsed = PackageHTTPRun.Role(rawValue: r) { role = parsed }
            else { problem(join(path, "role"), "Must be primary or reserve.") }
        }
        return PackageHTTPRun(method: method, url: url, query: query, headers: headers, json: json, form: form,
                              timeout: timeout, results: results, answer: answer, role: role)
    }

    /// `https` to a declared host; plain `http` only to a server setting on this Mac. Templates only
    /// after the host.
    mutating func checkURL(_ url: String, at path: String, hosts: [String], settings: [PackageSetting]) {
        guard !url.isEmpty else { return }
        if let serverID = url.firstMatch(of: #/^\{\{settings\.([a-z0-9_]+)\}\}/#)?.1 {
            if settings.first(where: { $0.id == String(serverID) })?.kind != .server {
                problem(path, "Only a server setting can start a URL.")
            }
            return
        }
        guard let parsed = URL(string: url.replacingOccurrences(of: "{{", with: "x").replacingOccurrences(of: "}}", with: "x")),
              let scheme = parsed.scheme?.lowercased(), let host = parsed.host?.lowercased() else {
            problem(path, "Must be an absolute https URL."); return
        }
        let authority = url.components(separatedBy: "://").dropFirst().first?.split(separator: "/").first ?? ""
        if authority.contains("{{") { problem(path, "Templates can't change the host.") }
        if scheme == "http" {
            problem(path, PackageValidator.isLoopback(host)
                ? "A server on this Mac is set by a server setting: start the URL with {{settings.<id>}}."
                : "Must be https.")
            return
        }
        guard scheme == "https" else { problem(path, "Must be https."); return }
        if parsed.port != nil { problem(path, "Ports aren't allowed.") }
        if !hosts.contains(host) { problem(path, "\"\(host)\" isn't in hosts.") }
    }
}

extension Bundle {
    /// Lasso's version, for `minLasso` and the User-Agent.
    var lassoVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
}
