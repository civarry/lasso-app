import Foundation

/// `lasso-pkg`: Lasso's package checks and runners on the command line, for authors and the catalog's
/// CI. Built from Lasso's own engine (`build.sh`), so a package that passes here passes in Lasso.
@main
struct LassoPkg {
    static let usage = """
    lasso-pkg \(LassoPkgVersion.lasso): check, run and share Lasso packages.

      lasso-pkg new <search|send|prompt|shortcut|script> <folder>   a starter package
      lasso-pkg validate <folder or lasso.json>... [--catalog]     every rule Lasso checks
      lasso-pkg run <folder> <command> [--text T] [--query Q] [--arg name=value]... [--setting id=value]... [--send]
      lasso-pkg pack <folder> [--out file.lassopkg]                 one file to share
      lasso-pkg index <packages folder> --base-url URL --out folder the catalog's index.json and downloads

    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first else { print(usage); exit(2) }
        args.removeFirst()
        do {
            switch verb {
            case "new": try new(args)
            case "validate": exit(try validate(args) ? 0 : 1)
            case "run": try await run(args)
            case "pack": try pack(args)
            case "index": try index(args)
            case "-h", "--help", "help": print(usage)
            default: fail("Unknown command \"\(verb)\".\n\n\(usage)")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    /// `--name value` options, and the rest in order.
    static func options(_ args: [String]) -> (positional: [String], values: [String: [String]], flags: Set<String>) {
        var positional: [String] = [], values: [String: [String]] = [:], flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if ["--catalog", "--send"].contains(a) { flags.insert(a) }
                else if i + 1 < args.count { values[a, default: []].append(args[i + 1]); i += 1 }
                else { fail("\(a) needs a value.") }
            } else { positional.append(a) }
            i += 1
        }
        return (positional, values, flags)
    }

    // MARK: Reading

    struct Loaded {
        var folder: URL?
        var manifest: Data
        var files: PackageFiles.Files
    }

    static func load(_ path: String) throws -> Loaded {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { fail("No such file or folder: \(path)") }
        if isDir.boolValue {
            let files: PackageFiles.Files
            do { files = try PackageFiles.read(url) } catch let e as PackageFiles.Invalid {
                fail(e.problems.map(\.description).joined(separator: "\n"))
            }
            return Loaded(folder: url, manifest: try Data(contentsOf: url.appending(path: "lasso.json")), files: files)
        }
        if url.pathExtension == PackageBundle.fileExtension {
            guard let unpacked = PackageBundle.unpack(try Data(contentsOf: url)) else { fail("\(path) isn't a readable .lassopkg.") }
            return Loaded(folder: nil, manifest: unpacked.manifest, files: unpacked.files)
        }
        return Loaded(folder: nil, manifest: try Data(contentsOf: url), files: [:])
    }

    /// Every problem Lasso would report, plus the catalog's own rules with `catalog`.
    static func problems(_ loaded: Loaded, catalog: Bool) -> (LassoPackage?, [String]) {
        switch PackageValidator.validate(loaded.manifest, lassoVersion: LassoPkgVersion.lasso) {
        case .invalid(let list): return (nil, list.map(\.description))
        case .valid(let package):
            var out = PackageFiles.problems(package, loaded.files).map(\.description)
            if catalog {
                if let folder = loaded.folder, folder.standardizedFileURL.lastPathComponent != package.id {
                    out.append("The folder must be named \(package.id), like its id.")
                }
                let readme = loaded.files["README.md"].map { String(decoding: $0, as: UTF8.self) } ?? ""
                if readme.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
                    out.append("README.md: say what it does, what it sends where, and what it needs.")
                }
            }
            return (package, out)
        }
    }

    // MARK: Commands

    static func new(_ args: [String]) throws {
        let o = options(args)
        guard o.positional.count == 2, let kind = PackageStarters.Kind(rawValue: o.positional[0]) else {
            fail("Usage: lasso-pkg new <\(PackageStarters.Kind.allCases.map(\.rawValue).joined(separator: "|"))> <folder>")
        }
        let folder = URL(fileURLWithPath: o.positional[1])
        let id = folder.lastPathComponent.lowercased()
        guard PackageValidator.matches(id, PackageValidator.idPattern) else {
            fail("Name the folder like a package id: 3 to 40 lowercase letters, digits and \"-\", starting with a letter.")
        }
        try PackageStarters.write(kind, id: id, to: folder)
        print("Made \(folder.path): \(kind.title). Edit lasso.json, then: lasso-pkg validate \(folder.path)")
    }

    static func validate(_ args: [String]) throws -> Bool {
        let o = options(args)
        guard !o.positional.isEmpty else { fail("Usage: lasso-pkg validate <folder or lasso.json>... [--catalog]") }
        var ok = true
        for path in o.positional {
            let (package, list) = problems(try load(path), catalog: o.flags.contains("--catalog"))
            if list.isEmpty {
                print("✓ \(path): \(package?.name ?? "") \(package?.version ?? "")")
            } else {
                ok = false
                print("✗ \(path): \(list.count) problem\(list.count == 1 ? "" : "s")")
                for line in list { print("  \(line)") }
            }
        }
        return ok
    }

    static func run(_ args: [String]) async throws {
        let o = options(args)
        guard o.positional.count == 2 else { fail("Usage: lasso-pkg run <folder> <command> [--text T] [--query Q] [--arg name=value] [--send]") }
        let loaded = try load(o.positional[0])
        let (found, list) = problems(loaded, catalog: false)
        guard let package = found, list.isEmpty else { fail(list.joined(separator: "\n")) }
        guard let command = package.command(o.positional[1]) else {
            fail("No command \"\(o.positional[1])\". It has: \(package.commands.map(\.id).joined(separator: ", ")).")
        }
        func pairs(_ key: String) -> [String: String] {
            Dictionary((o.values[key] ?? []).compactMap { pair -> (String, String)? in
                guard let eq = pair.firstIndex(of: "=") else { return nil }
                return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
            }, uniquingKeysWith: { _, new in new })
        }
        let text = o.values["--text"]?.last ?? command.testText ?? ""
        let query = o.values["--query"]?.last ?? command.testQuery ?? ""
        let args = pairs("--arg").isEmpty ? command.testArgs : pairs("--arg")
        let settings = pairs("--setting")
        var values: [String: String] = ["text": text, "query": query, "language": "English", "source.app": "", "source.url": ""]
        for setting in package.settings { values["settings.\(setting.id)"] = settings[setting.id] ?? setting.defaultValue ?? "" }
        for (k, v) in args { values["args.\(k)"] = v }
        let secrets = package.settings.filter { $0.kind == .secret }.compactMap { settings[$0.id] }.filter { !$0.isEmpty }
        if let why = await PackageRequirements.missing(package) { fail(why) }

        switch command.runner {
        case .prompt(let run):
            print("Runs on the model chosen in Lasso. The prompt, with the text fenced as Lasso sends it:\n")
            print(PackageTemplate.render(run.prompt, values, .raw))
        case .http(let run):
            let request = try PackageHTTP.request(run, values: values)
            print("\(request.httpMethod ?? "GET") \(PackageHTTP.redact(request.url?.absoluteString ?? "", secrets: secrets))")
            for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
                print("\(name): \(PackageHTTP.redact(value, secrets: secrets))")
            }
            if let body = request.httpBody { print("\n" + PackageHTTP.redact(String(decoding: body, as: UTF8.self), secrets: secrets)) }
            guard o.flags.contains("--send") else { print("\n(Not sent. Add --send to send it.)"); return }
            let json = try await PackageHTTP.send(request, allowed: PackageHTTP.allowedHosts(package, values: values), localOnly: false)
            if let map = run.results {
                let hits = PackageHTTP.results(json, map: map, source: package.name)
                print("\n\(hits.count) result\(hits.count == 1 ? "" : "s"):")
                for hit in hits { print("- \(hit.title)  \(hit.url?.absoluteString ?? "")") }
            } else {
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                print("\n" + PackageHTTP.redact(String(decoding: data, as: UTF8.self), secrets: secrets))
            }
        case .shortcut(let run):
            print(try await PackageShortcut.run(run, text: command.input.contains(.text) ? text : nil))
        case .script(let run):
            guard let folder = loaded.folder else { fail("Run a script package from its folder.") }
            let scratch = FileManager.default.temporaryDirectory.appending(path: "lasso-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            var stdin: [String: Any] = ["command": command.id]
            if command.input.contains(.text) { stdin["text"] = text }
            if command.input.contains(.query) { stdin["query"] = query }
            if command.input.contains(.args) { stdin["args"] = args }
            stdin["settings"] = Dictionary(uniqueKeysWithValues: package.settings.filter { $0.kind != .secret }.map { ($0.id, values["settings.\($0.id)"] ?? "") })
            let input = try JSONSerialization.data(withJSONObject: stdin, options: [.sortedKeys])
            print("Standard input: \(String(decoding: input, as: UTF8.self))")
            var env: [String: String] = [:]
            for setting in package.settings where setting.kind == .secret { env["LASSO_SECRET_\(setting.id.uppercased())"] = settings[setting.id] ?? "" }
            let folders = package.settings.filter { $0.kind == .folder }.compactMap { values["settings.\($0.id)"] }.filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let places = PackageScript.Places(package: folder, data: scratch.appending(path: "data", directoryHint: .isDirectory),
                                              workspace: scratch.appending(path: "workspace", directoryHint: .isDirectory), folders: folders)
            let output = try await PackageScript.run(.init(command: command.id, stdin: input, secrets: env, run: run, localOnly: false),
                                                     places: places, progress: { print("progress: \($0)") })
            switch output {
            case .text(let t): print("\n" + PackageHTTP.redact(t, secrets: secrets))
            case .url(let u): print("\nurl: \(u)")
            case .file(let f):
                let kept = FileManager.default.currentDirectoryPath + "/" + f.lastPathComponent
                try? FileManager.default.removeItem(atPath: kept)
                try FileManager.default.copyItem(at: f, to: URL(fileURLWithPath: kept))
                print("\nfile: \(kept)")
            case .results(let list):
                print("\n\(list.count) result\(list.count == 1 ? "" : "s"):")
                for item in list { print("- \(item["title"] ?? "")  \(item["url"] ?? "")") }
            }
        }
    }

    static func pack(_ args: [String]) throws {
        let o = options(args)
        guard o.positional.count == 1 else { fail("Usage: lasso-pkg pack <folder> [--out file.lassopkg]") }
        let loaded = try load(o.positional[0])
        let (found, list) = problems(loaded, catalog: false)
        guard let package = found, list.isEmpty else { fail(list.joined(separator: "\n")) }
        let out = URL(fileURLWithPath: o.values["--out"]?.last ?? "\(package.id)-\(package.version).\(PackageBundle.fileExtension)")
        let data = try PackageBundle.pack(manifest: loaded.manifest, files: loaded.files)
        try data.write(to: out)
        print("Packed \(out.path) (\(data.count.formatted()) bytes, sha256 \(PackageFiles.sha256(data)))")
    }

    /// The catalog's `index.json` and one `.lassopkg` per package, from `packages/<id>/` folders.
    static func index(_ args: [String]) throws {
        let o = options(args)
        guard o.positional.count == 1, let base = o.values["--base-url"]?.last, let outPath = o.values["--out"]?.last else {
            fail("Usage: lasso-pkg index <packages folder> --base-url URL --out folder")
        }
        let root = URL(fileURLWithPath: o.positional[0], isDirectory: true)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out.appending(path: "dist"), withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            let loaded = try load(folder.path)
            let (found, list) = problems(loaded, catalog: true)
            guard let package = found, list.isEmpty else { fail("\(folder.lastPathComponent):\n" + list.joined(separator: "\n")) }
            let name = "\(package.id)-\(package.version).\(PackageBundle.fileExtension)"
            let data = try PackageBundle.pack(manifest: loaded.manifest, files: loaded.files)
            try data.write(to: out.appending(path: "dist/\(name)"))
            var entry: [String: Any] = [
                "id": package.id, "version": package.version, "name": package.name, "summary": package.summary,
                "author": package.author, "url": "\(base.hasSuffix("/") ? base : base + "/")dist/\(name)",
                "sha256": PackageFiles.sha256(data),
                "commands": package.commands.map { ["title": $0.title, "surfaces": $0.surfaces.map(\.rawValue)] },
                "permissions": permissions(package),
            ]
            if let category = package.category { entry["category"] = category }
            if let minLasso = package.minLasso { entry["minLasso"] = minLasso }
            if let symbol = package.iconSymbol { entry["symbol"] = symbol }
            if let domain = package.iconDomain { entry["domain"] = domain }
            entries.append(entry)
        }
        let index: [String: Any] = ["lasso": 1, "packages": entries]
        try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "index.json"))
        print("Indexed \(entries.count) package\(entries.count == 1 ? "" : "s") into \(out.path)")
    }

    /// What a package can do, as short tags for Browse: hosts, keys, code, Shortcuts, patches.
    static func permissions(_ package: LassoPackage) -> [String: Any] {
        var out: [String: Any] = ["hosts": package.hosts]
        if package.settings.contains(where: { $0.kind == .secret }) { out["key"] = true }
        if package.commands.contains(where: { $0.script != nil }) { out["script"] = true }
        if package.commands.contains(where: { $0.script?.network == true }) { out["network"] = true }
        if package.commands.contains(where: { $0.shortcut != nil }) { out["shortcut"] = true }
        if package.commands.contains(where: { $0.prompt != nil }) { out["model"] = true }
        if !package.patches.isEmpty { out["patches"] = true }
        return out
    }
}
