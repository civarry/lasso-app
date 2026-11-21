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
    /// Apps and command-line tools it needs (spec, "Requirements").
    var requires: [PackageRequirement] = []
    /// Edits to Lasso's own content (spec, "Patches").
    var patches: [PackagePatch] = []

    func setting(_ id: String) -> PackageSetting? { settings.first { $0.id == id } }
    func command(_ id: String) -> PackageCommand? { commands.first { $0.id == id } }
}

/// Something a package needs on the Mac. Lasso checks it and never installs it.
enum PackageRequirement: Sendable, Equatable {
    /// A command-line tool on Lasso's `PATH`, with the line that installs it.
    case command(String, install: String?)
    /// An app, by bundle id.
    case app(String)
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

    enum Runner: Sendable, Equatable {
        case http(PackageHTTPRun)
        case prompt(PackagePromptRun)
        case shortcut(PackageShortcutRun)
        case script(PackageScriptRun)
    }

    var id: String
    var title: String
    var symbol: String?
    var surfaces: [Surface]
    var input: [Input]
    var output: Output
    var runner: Runner
    var when: PackageWhen?
    var testQuery: String?
    var testText: String?
    /// The `tool` surface's definition for models.
    var tool: PackageTool? = nil
    /// Sample tool arguments for the Test button.
    var testArgs: [String: String] = [:]

    var http: PackageHTTPRun? { if case .http(let h) = runner { h } else { nil } }
    var prompt: PackagePromptRun? { if case .prompt(let p) = runner { p } else { nil } }
    var shortcut: PackageShortcutRun? { if case .shortcut(let s) = runner { s } else { nil } }
    /// A search command's role: an http one says; a script (on this Mac, no quota) runs on every search.
    var searchRole: PackageHTTPRun.Role { http?.role ?? .primary }
    var script: PackageScriptRun? { if case .script(let s) = runner { s } else { nil } }
}

/// The `shortcut` runner: one of the user's Shortcuts, run by `/usr/bin/shortcuts`.
struct PackageShortcutRun: Sendable, Equatable {
    var name: String
    /// An iCloud link to get the Shortcut, while the user doesn't have it.
    var get: URL?
    /// The author says it works without the internet (Lasso can't check).
    var offline: Bool
    var timeout: Double
}

/// The `script` runner: a program in the package's `scripts/` folder, run in a sandbox.
struct PackageScriptRun: Sendable, Equatable {
    /// Relative to the package folder, inside `scripts/`.
    var path: String
    var network: Bool
    var timeout: Double
}

/// A command as a tool for the chat model and the Agent (spec, "Model and Agent tools").
struct PackageTool: Sendable, Equatable {
    enum ArgType: String, Sendable, CaseIterable { case string, number, boolean }
    struct Arg: Sendable, Equatable {
        var name: String
        var type: ArgType
    }
    var name: String
    var description: String
    /// Sorted by name, all required.
    var args: [Arg]

    static let namePattern = "[a-z][a-z0-9_]{0,39}"

    /// A JSON number or boolean as template text: `3`, `2.5`, `true`.
    static func text(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        let double = number.doubleValue
        return double == double.rounded() && abs(double) < 1e15 ? String(Int(double)) : String(double)
    }
    static let maxArgs = 6
    static let maxDescription = 200
}

/// The `prompt` runner: a prompt run on the model chosen in Lasso's Settings.
struct PackagePromptRun: Sendable, Equatable {
    var prompt: String
    var system: String?
}

/// Where a command is offered (spec, "When"). Every condition given must hold.
struct PackageWhen: Sendable, Equatable {
    var match: String?
    var detects: [String] = []
    var apps: [String] = []
    var minLength: Int?
    var maxLength: Int?
    var hasImage: Bool?

    static let detectable: Set<String> = ["link", "email", "phone", "address", "date", "flight", "tracking", "money"]
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
        let requires = self.requires(root["requires"])
        let patches = root["patches"].map { PackagePatch.read($0, problem: { self.problem($0, $1) }) } ?? []

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
                            hosts: hosts, settings: settings, limits: limits, minLasso: minLasso, commands: commands,
                            requires: requires, patches: patches)
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
            if kind == .folder, o["default"] != nil { problem(join(path, "default"), "The user picks the folder: it can't have a default.") }
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
                surfaces.append(surface)
            }
        } else { problem(join(path, "surfaces"), "Required: a list of where the command appears.") }
        let isSearch = surfaces.contains(.search)
        if isSearch, surfaces.count > 1 { problem(join(path, "surfaces"), "A search command can't appear anywhere else.") }

        var inputs: [PackageCommand.Input] = []
        if let list = o["input"] as? [String] {
            for (i, name) in list.enumerated() {
                guard let input = PackageCommand.Input(rawValue: name) else {
                    problem("\(path).input[\(i)]", "Unknown input \"\(name)\"."); continue
                }
                if input == .image { problem("\(path).input[\(i)]", "This version of Lasso can't give commands images yet.") }
                if input == .args, surfaces != [.tool] {
                    problem("\(path).input[\(i)]", "\"args\" is only for commands whose one surface is \"tool\": elsewhere no model fills them in.")
                }
                if input == .query, !isSearch { problem("\(path).input[\(i)]", "\"query\" is only for search commands.") }
                inputs.append(input)
            }
        } else if o["input"] != nil { problem(join(path, "input"), "Must be a list.") }

        let outputName = string(o, "output", at: path) ?? ""
        let output = PackageCommand.Output(rawValue: outputName)
        if !outputName.isEmpty, output == nil { problem(join(path, "output"), "Unknown output \"\(outputName)\".") }
        let runsCode = (o["run"] as? [String: Any]).map { $0["script"] != nil || $0["shortcut"] != nil } ?? false
        if output == .image || output == .file {
            if !runsCode { problem(join(path, "output"), "\"\(outputName)\" output comes from a script or a Shortcut.") }
            if let bad = surfaces.first(where: { ![.toolbar, .slash, .hotkey].contains($0) }) {
                problem(join(path, "output"), "\"\(outputName)\" output is for the toolbar, chat commands and hotkeys, not \(bad.rawValue).")
            }
        }
        if isSearch {
            if inputs != [.query] { problem(join(path, "input"), "A search command takes [\"query\"].") }
            if output != .results { problem(join(path, "output"), "A search command's output is \"results\".") }
        } else if output == .results {
            problem(join(path, "output"), "\"results\" is only for search commands.")
        }
        // Pasting over text only makes sense for text highlighted in an app: a capture's text was
        // read from pixels, and a chat reply isn't editable.
        if output == .replace, surfaces.contains(where: { $0 != .hotkey }) {
            problem(join(path, "output"), "\"replace\" is only for hotkey commands (it pastes over the highlighted text).")
        }
        if output == .replace, !inputs.contains(.text) {
            problem(join(path, "input"), "\"replace\" needs the \"text\" input.")
        }

        if surfaces.contains(.send), let output, ![.notify, .copy, .open].contains(output) {
            problem(join(path, "output"), "A Send to command's output is notify, copy or open.")
        }
        if output == .open, o["run"].flatMap({ ($0 as? [String: Any])?["prompt"] }) != nil {
            problem(join(path, "output"), "\"open\" needs an http command: a model's answer can't choose what opens.")
        }

        var when: PackageWhen?
        if let raw = o["when"] {
            when = self.when(raw, at: join(path, "when"))
            if isSearch { problem(join(path, "when"), "\"when\" doesn't apply to search commands.") }
            if when?.hasImage == true, surfaces.contains(.hotkey) || surfaces.contains(.slash) {
                problem(join(join(path, "when"), "hasImage"), "Hotkeys and chat commands run on text, never an image.")
            }
        }
        var tool: PackageTool?
        if let raw = o["tool"] {
            if surfaces.contains(.tool) { tool = self.tool(raw, at: join(path, "tool")) }
            else { problem(join(path, "tool"), "Only for commands with the \"tool\" surface.") }
        } else if surfaces.contains(.tool) {
            problem(join(path, "tool"), "Required with the \"tool\" surface: a name, a description and the arguments.")
        }
        if let tool, inputs.contains(.text), !tool.args.contains(where: { $0.name == "text" }) {
            problem(join(join(path, "tool"), "args"), "The command takes \"text\", so the tool needs a \"text\" argument for the model to fill in.")
        }
        if tool != nil, let output, ![.markdown, .copy, .notify, .open].contains(output) {
            problem(join(path, "output"), "A tool's output is markdown, copy, notify or open.")
        }

        var testQuery: String?, testText: String?, testArgs: [String: String] = [:]
        if let test = o["test"] {
            if let t = test as? [String: Any] {
                onlyKnown(t, ["text", "query", "args", "image"], at: join(path, "test"))
                testQuery = string(t, "query", at: join(path, "test"), required: false)
                testText = string(t, "text", at: join(path, "test"), required: false)
                if let raw = t["args"] {
                    if let args = raw as? [String: Any] {
                        for (key, value) in args {
                            if let v = value as? String { testArgs[key] = v }
                            else if let n = value as? NSNumber { testArgs[key] = PackageTool.text(n) }
                            else { problem("\(join(path, "test")).args.\(key)", "Must be text, a number or true/false.") }
                        }
                        if let tool {
                            for key in testArgs.keys where !tool.args.contains(where: { $0.name == key }) {
                                problem("\(join(path, "test")).args.\(key)", "The tool has no argument \"\(key)\".")
                            }
                        }
                    } else { problem(join(join(path, "test"), "args"), "Must be an object.") }
                }
            } else { problem(join(path, "test"), "Must be an object.") }
        }
        if isSearch, testQuery?.isEmpty != false {
            problem(join(path, "test"), "A search command needs a test query, like {\"query\": \"lasso app\"}.")
        }

        guard let runObject = o["run"] as? [String: Any] else { problem(join(path, "run"), "Required."); return nil }
        var names = Set(inputs.map(\.rawValue)).union(["language"])
        if inputs.contains(.source) { names.formUnion(["source.app", "source.url"]); names.remove("source") }
        if inputs.contains(.args) {
            names.remove("args")
            names.formUnion((tool?.args ?? []).map { "args.\($0.name)" })
        }
        guard let runner = self.runner(runObject, at: join(path, "run"), hosts: hosts, settings: settings,
                                       values: names, output: output, isSearch: isSearch) else { return nil }
        guard let output else { return nil }
        return PackageCommand(id: id, title: title, symbol: symbol, surfaces: surfaces, input: inputs, output: output,
                              runner: runner, when: when, testQuery: testQuery, testText: testText,
                              tool: tool, testArgs: testArgs)
    }

    mutating func tool(_ raw: Any, at path: String) -> PackageTool? {
        guard let o = raw as? [String: Any] else { problem(path, "Must be an object."); return nil }
        onlyKnown(o, ["name", "description", "args"], at: path)
        let name = string(o, "name", at: path, length: 1...40) ?? ""
        if !name.isEmpty, !PackageValidator.matches(name, PackageTool.namePattern) {
            problem(join(path, "name"), "Lowercase letters, digits and \"_\", starting with a letter.")
        }
        let description = string(o, "description", at: path, length: 1...PackageTool.maxDescription) ?? ""
        var args: [PackageTool.Arg] = []
        if let raw = o["args"] {
            if let object = raw as? [String: Any] {
                if object.count > PackageTool.maxArgs { problem(join(path, "args"), "At most \(PackageTool.maxArgs) arguments.") }
                for key in object.keys.sorted() {
                    if !PackageValidator.matches(key, PackageTool.namePattern) {
                        problem("\(path).args.\(key)", "Lowercase letters, digits and \"_\", starting with a letter.")
                    }
                    guard let typeName = object[key] as? String, let type = PackageTool.ArgType(rawValue: typeName) else {
                        problem("\(path).args.\(key)", "Must be \"string\", \"number\" or \"boolean\"."); continue
                    }
                    args.append(.init(name: key, type: type))
                }
            } else { problem(join(path, "args"), "Must be an object of name: type.") }
        }
        guard !name.isEmpty, !description.isEmpty else { return nil }
        return PackageTool(name: name, description: description, args: args)
    }

    mutating func when(_ raw: Any, at path: String) -> PackageWhen? {
        guard let o = raw as? [String: Any] else { problem(path, "Must be an object."); return nil }
        onlyKnown(o, ["match", "detects", "apps", "minLength", "maxLength", "hasImage"], at: path)
        var when = PackageWhen()
        if let match = string(o, "match", at: path, required: false, length: 1...200) {
            if (try? NSRegularExpression(pattern: match)) == nil { problem(join(path, "match"), "Isn't a valid regular expression.") }
            when.match = match
        }
        if let raw = o["detects"] {
            if let list = raw as? [String] {
                for (i, kind) in list.enumerated() where !PackageWhen.detectable.contains(kind) {
                    problem("\(path).detects[\(i)]", "Must be one of: \(PackageWhen.detectable.sorted().joined(separator: ", ")).")
                }
                when.detects = list
            } else { problem(join(path, "detects"), "Must be a list.") }
        }
        if let raw = o["apps"] {
            if let list = raw as? [String] { when.apps = list } else { problem(join(path, "apps"), "Must be a list of bundle ids.") }
        }
        when.minLength = int(o, "minLength", at: path, range: 0...1_000_000)
        when.maxLength = int(o, "maxLength", at: path, range: 1...1_000_000)
        if let raw = o["hasImage"] {
            if let b = raw as? Bool { when.hasImage = b } else { problem(join(path, "hasImage"), "Must be true or false.") }
        }
        return when
    }

    mutating func runner(_ o: [String: Any], at path: String, hosts: [String], settings: [PackageSetting],
                         values: Set<String>, output: PackageCommand.Output?, isSearch: Bool) -> PackageCommand.Runner? {
        onlyKnown(o, ["http", "prompt", "system", "shortcut", "script", "results", "answer", "role"], at: path)
        let present = ["http", "prompt", "shortcut", "script"].filter { o[$0] != nil }
        if present.isEmpty { problem(path, "Needs exactly one runner: http, prompt, shortcut or script."); return nil }
        if present.count > 1 { problem(path, "Use one runner, not \(present.joined(separator: " and ")).") ; return nil }
        let allowed = values.union(settings.map { "settings.\($0.id)" })

        if o["shortcut"] != nil || o["script"] != nil {
            for key in ["results", "answer", "role", "system"] where o[key] != nil {
                problem(join(path, key), key == "system" ? "Only for prompt commands." : "Only for http commands.")
            }
            if output == .open {
                problem(join(path, "output"), "\"open\" needs an http command: Lasso builds the address itself.")
            }
        }
        if let raw = o["shortcut"] {
            let sp = join(path, "shortcut")
            guard let s = raw as? [String: Any] else { problem(sp, "Must be an object."); return nil }
            onlyKnown(s, ["name", "get", "offline", "timeout"], at: sp)
            if isSearch { problem(sp, "A search command runs over http or as a script.") }
            let name = string(s, "name", at: sp, length: 1...100) ?? ""
            var get: URL?
            if let link = string(s, "get", at: sp, required: false) {
                get = URL(string: link)
                if get?.scheme != "https" || get?.host != "www.icloud.com" || !(get?.path.hasPrefix("/shortcuts/") ?? false) {
                    problem(join(sp, "get"), "Must be an https://www.icloud.com/shortcuts/ link.")
                }
            }
            var offline = false
            if let raw = s["offline"] { if let b = raw as? Bool { offline = b } else { problem(join(sp, "offline"), "Must be true or false.") } }
            let timeout = seconds(s, at: sp, max: 120)
            return .shortcut(PackageShortcutRun(name: name, get: get, offline: offline, timeout: timeout))
        }
        if let raw = o["script"] {
            let sp = join(path, "script")
            guard let s = raw as? [String: Any] else { problem(sp, "Must be an object."); return nil }
            onlyKnown(s, ["path", "network", "timeout"], at: sp)
            let file = string(s, "path", at: sp) ?? ""
            let parts = file.split(separator: "/", omittingEmptySubsequences: false)
            if !file.isEmpty, parts.count < 2 || parts[0] != "scripts" || parts.contains("..") || parts.contains("") || parts.contains(".") {
                problem(join(sp, "path"), "Must be a file in the package's scripts/ folder, like scripts/run.sh.")
            }
            var network = false
            if let raw = s["network"] { if let b = raw as? Bool { network = b } else { problem(join(sp, "network"), "Must be true or false.") } }
            let timeout = seconds(s, at: sp, max: 300)
            return .script(PackageScriptRun(path: file, network: network, timeout: timeout))
        }

        if o["prompt"] != nil {
            for key in ["results", "answer", "role"] where o[key] != nil {
                problem(join(path, key), "Only for http commands.")
            }
            if isSearch { problem(join(path, "prompt"), "A search command runs over http.") }
            let prompt = string(o, "prompt", at: path, length: 1...4000) ?? ""
            let system = string(o, "system", at: path, required: false, length: 1...1000)
            for (field, template) in [(join(path, "prompt"), prompt), (join(path, "system"), system ?? "")] {
                for name in PackageTemplate.names(in: template) where !allowed.contains(name) {
                    problem(field, "Unknown value {{\(name)}}.")
                }
            }
            for setting in settings where setting.kind == .secret {
                if (prompt + (system ?? "")).contains("{{settings.\(setting.id)}}") {
                    problem(join(path, "prompt"), "A secret can't go into a prompt: it would be sent to the model.")
                }
            }
            return .prompt(PackagePromptRun(prompt: prompt, system: system))
        }
        if o["system"] != nil { problem(join(path, "system"), "Only for prompt commands.") }
        guard let http = o["http"] as? [String: Any] else { return nil }
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
        if output == .open {
            if method != "GET" || json != nil || form != nil || !headers.isEmpty {
                problem(hp, "An \"open\" command is a page address: GET, with no headers or body.")
            }
        }

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
        if output == .results || output == .open, answer != nil { problem(join(path, "answer"), "Not used with \"\(output?.rawValue ?? "")\" output.") }
        var role = PackageHTTPRun.Role.primary
        if let r = string(o, "role", at: path, required: false) {
            if !isSearch { problem(join(path, "role"), "Only for search commands.") }
            if let parsed = PackageHTTPRun.Role(rawValue: r) { role = parsed }
            else { problem(join(path, "role"), "Must be primary or reserve.") }
        }
        return .http(PackageHTTPRun(method: method, url: url, query: query, headers: headers, json: json, form: form,
                                    timeout: timeout, results: results, answer: answer, role: role))
    }

    /// `timeout`: 1 to `max` seconds, 30 by default.
    mutating func seconds(_ o: [String: Any], at path: String, max: Double) -> Double {
        guard let t = o["timeout"] else { return 30 }
        if let n = (t as? NSNumber)?.doubleValue, (1...max).contains(n), CFGetTypeID(t as CFTypeRef) != CFBooleanGetTypeID() { return n }
        problem(join(path, "timeout"), "Must be 1 to \(Int(max)) seconds.")
        return 30
    }

    mutating func requires(_ raw: Any?) -> [PackageRequirement] {
        guard let raw else { return [] }
        guard let list = raw as? [Any], list.count <= 8 else { problem("requires", "Must be a list of at most 8 requirements."); return [] }
        var out: [PackageRequirement] = []
        for (i, item) in list.enumerated() {
            let path = "requires[\(i)]"
            guard let o = item as? [String: Any] else { problem(path, "Must be an object."); continue }
            onlyKnown(o, ["command", "install", "app"], at: path)
            if let app = o["app"] {
                if o["command"] != nil || o["install"] != nil { problem(path, "Use app, or command with install, not both.") }
                guard let id = app as? String, PackageValidator.matches(id, "[A-Za-z0-9][A-Za-z0-9.-]{2,154}") else {
                    problem(join(path, "app"), "Must be an app's bundle id, like com.apple.Notes."); continue
                }
                out.append(.app(id))
            } else if let command = string(o, "command", at: path, length: 1...60) {
                if !PackageValidator.matches(command, "[A-Za-z0-9][A-Za-z0-9._+-]*") {
                    problem(join(path, "command"), "Must be a program's name, like pandoc."); continue
                }
                out.append(.command(command, install: string(o, "install", at: path, required: false, length: 1...200)))
            }
        }
        return out
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
