import Foundation
import Testing
@testable import Lasso

/// The `script` and `shortcut` runners (spec, "Verification": script sandbox, environment, timeout,
/// local-only, Shortcut existence, full access).
@Suite(.serialized)
struct PackageScriptTests {
    /// A package folder with one script, and the places it runs in, all under a temp folder.
    struct Fixture {
        let root: URL
        let places: PackageScript.Places
        let id: String

        init(_ script: String) throws {
            id = "test-\(UUID().uuidString.prefix(8).lowercased())"
            root = FileManager.default.temporaryDirectory.appending(path: "lasso-script-tests-\(id)", directoryHint: .isDirectory)
            let package = root.appending(path: "package", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package.appending(path: "scripts"), withIntermediateDirectories: true)
            let file = package.appending(path: "scripts/run.sh")
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            places = PackageScript.Places(package: package, data: root.appending(path: "data", directoryHint: .isDirectory),
                                          workspace: root.appending(path: "workspace", directoryHint: .isDirectory), folders: [])
        }

        func run(stdin: String = "{}", secrets: [String: String] = [:], network: Bool = false, timeout: Double = 10,
                 unsandboxed: Bool = false, localOnly: Bool = false) async throws -> PackageScript.Output {
            try await PackageScript.run(.init(command: "run", stdin: Data(stdin.utf8), secrets: secrets,
                                              run: PackageScriptRun(path: "scripts/run.sh", network: network, timeout: timeout),
                                              unsandboxed: unsandboxed, localOnly: localOnly), places: places)
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    /// A file in the home folder the sandbox must keep out (not a TCC-protected folder, so only the
    /// sandbox can be what stops it).
    private func homeProbe() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/lasso-sandbox-probe-\(UUID().uuidString.prefix(6)).txt")
        try Data("secret-ish".utf8).write(to: url)
        return url
    }

    @Test func theSandboxKeepsAScriptToItsOwnFolders() async throws {
        let probe = try homeProbe()
        defer { try? FileManager.default.removeItem(at: probe) }
        let leak = FileManager.default.homeDirectoryForCurrentUser.appending(path: "lasso-sandbox-leak-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: leak) }
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/.GlobalPreferences.plist")
        let f = try Fixture("""
            #!/bin/sh
            cat "\(probe.path)" >/dev/null 2>&1 && echo "read-home:yes" || echo "read-home:no"
            cat "\(prefs.path)" >/dev/null 2>&1 && echo "read-prefs:yes" || echo "read-prefs:no"
            echo x > "\(leak.path)" 2>/dev/null && echo "write-home:yes" || echo "write-home:no"
            echo x > "$HOME/data.txt" && echo "write-data:yes" || echo "write-data:no"
            echo x > "$TMPDIR/tmp.txt" && echo "write-tmp:yes" || echo "write-tmp:no"
            """)
        defer { f.clean() }
        guard case .text(let out) = try await f.run() else { Issue.record("not text"); return }
        #expect(out.contains("read-home:no"), "\(out)")
        #expect(out.contains("read-prefs:no"), "\(out)")
        #expect(out.contains("write-home:no"), "\(out)")
        #expect(out.contains("write-data:yes"), "\(out)")
        #expect(out.contains("write-tmp:yes"), "\(out)")
        #expect(!FileManager.default.fileExists(atPath: leak.path))

        // Full access is the user's choice: the same script then reads the home folder.
        guard case .text(let full) = try await f.run(unsandboxed: true) else { Issue.record("not text"); return }
        #expect(full.contains("read-home:yes"), "\(full)")
    }

    @Test func theNetworkOnlyWhenDeclaredAndNeverInLocalOnly() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        let f = try Fixture("""
            #!/bin/sh
            /usr/bin/curl -s -m 3 "\(server.base)/hit" >/dev/null 2>&1 && echo "net:yes" || echo "net:no"
            """)
        defer { f.clean() }
        guard case .text(let none) = try await f.run() else { Issue.record("not text"); return }
        #expect(none == "net:no")
        #expect(server.requests.isEmpty)
        guard case .text(let local) = try await f.run(network: true, localOnly: true) else { Issue.record("not text"); return }
        #expect(local == "net:no")
        #expect(server.requests.isEmpty)
        guard case .text(let allowed) = try await f.run(network: true) else { Issue.record("not text"); return }
        #expect(allowed == "net:yes")
        #expect(server.requests.count == 1)
    }

    @Test func theScriptSeesOnlyTheDocumentedEnvironment() async throws {
        let f = try Fixture("""
            #!/bin/sh
            env | cut -d= -f1 | grep -v -e '^_$' -e '^PWD$' -e '^SHLVL$' | sort | tr '\\n' ' '
            echo
            echo "secret=$LASSO_SECRET_KEY"
            cat
            """)
        defer { f.clean() }
        let entryJSON = #"{"command":"run","settings":{"style":"Short"},"text":"hello"}"#
        guard case .text(let out) = try await f.run(stdin: entryJSON, secrets: ["LASSO_SECRET_KEY": "sk-123"]) else {
            Issue.record("not text"); return
        }
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "HOME LANG LASSO_SECRET_KEY PATH TMPDIR ", "\(out)")
        #expect(lines.contains("secret=sk-123"))
        #expect(lines.last == entryJSON)
    }

    @Test func theStandardInputHasOnlyDeclaredInputsAndNoSecrets() throws {
        let package = try #require(PackageValidator.validate(Data("""
            {"lasso": 1, "id": "env-check", "version": "1.0.0", "name": "Env", "summary": "x", "author": "Me",
             "settings": [{"id": "key", "label": "API key", "kind": "secret"}, {"id": "style", "label": "Style", "kind": "text"}],
             "commands": [{"id": "run", "title": "Run", "surfaces": ["toolbar"], "input": ["text"], "output": "markdown",
                           "run": {"script": {"path": "scripts/run.sh"}}}]}
            """.utf8)).package, "\(PackageValidator.validate(Data()).problems)")
        let entry = PackageRegistry.Entry(package: package, values: ["settings.key": "sk-123", "settings.style": "Short"],
                                          secrets: ["sk-123"], ready: true)
        let data = PackageScript.stdin(entry, package.commands[0], input: PackageInput(text: "hi", sourceApp: "Safari", args: ["a": "b"]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"command":"run","settings":{"style":"Short"},"text":"hi"}"#)
        #expect(PackageScript.secrets(entry) == ["LASSO_SECRET_KEY": "sk-123"])
    }

    @Test func aTimeLimitStopsTheScriptAndWhatItStarted() async throws {
        let f = try Fixture("""
            #!/bin/sh
            (sleep 2; touch "$HOME/child-ran") &
            sleep 30
            """)
        defer { f.clean() }
        let started = Date()
        await #expect(throws: PackageScript.RunError.timedOut(1)) { try await f.run(timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 4)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!FileManager.default.fileExists(atPath: f.places.data.appending(path: "child-ran").path))
    }

    @Test func outputsAreReadAndFilesLandInTheWorkspace() async throws {
        let f = try Fixture("""
            #!/bin/sh
            printf 'a,b\\n1,2\\n' > "$TMPDIR/table.csv"
            echo "{\\"path\\": \\"$TMPDIR/table.csv\\"}"
            """)
        defer { f.clean() }
        guard case .file(let url) = try await f.run() else { Issue.record("not a file"); return }
        #expect(url.deletingLastPathComponent().resolvingSymlinksInPath() == f.places.workspace.resolvingSymlinksInPath())
        #expect(try String(contentsOf: url, encoding: .utf8) == "a,b\n1,2\n")

        let outside = try Fixture("#!/bin/sh\necho '{\"path\": \"/etc/hosts\"}'\n")
        defer { outside.clean() }
        await #expect(throws: PackageScript.RunError.self) { try await outside.run() }

        let failing = try Fixture("#!/bin/sh\necho 'first' >&2\necho 'progress: half' >&2\necho 'Needs a table.' >&2\nexit 3\n")
        defer { failing.clean() }
        await #expect(throws: PackageScript.RunError.failed("Needs a table.")) { try await failing.run() }

        let plain = try Fixture("#!/bin/sh\necho '{\"results\": [{\"title\": \"Notes\", \"url\": \"file:///tmp/a.md\"}]}'\n")
        defer { plain.clean() }
        #expect(try await plain.run() == .results([["title": "Notes", "url": "file:///tmp/a.md"]]))
    }

    @Test func aScriptOutsideItsPackageIsRefused() async throws {
        let f = try Fixture("#!/bin/sh\necho hi\n")
        defer { f.clean() }
        try FileManager.default.removeItem(at: f.places.package.appending(path: "scripts/run.sh"))
        try FileManager.default.createSymbolicLink(at: f.places.package.appending(path: "scripts/run.sh"),
                                                   withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        await #expect(throws: PackageScript.RunError.missing("scripts/run.sh")) { try await f.run() }
    }

    @Test func aShortcutTheUserLacksIsntRun() async throws {
        let run = PackageShortcutRun(name: "Lasso test \(UUID().uuidString)", get: nil, offline: true, timeout: 10)
        await #expect(throws: PackageShortcut.RunError.notInstalled(run.name)) { try await PackageShortcut.run(run, text: "x") }
    }
}

/// Folder packages in the store: scripts come with the folder, a change on disk turns it off, full
/// access is the user's and doesn't survive a changed script, and removing deletes its data.
@MainActor
@Suite(.serialized)
struct PackageFolderTests {
    static let manifest = """
    {"lasso": 1, "id": "table-to-csv", "version": "1.0.0", "name": "Table to CSV", "summary": "Tables to CSV.", "author": "Me",
     "commands": [{"id": "to-csv", "title": "Table to CSV", "surfaces": ["toolbar"], "input": ["text"], "output": "file",
                   "run": {"script": {"path": "scripts/to-csv.sh", "timeout": 10}}}]}
    """
    static let script = Data("#!/bin/sh\ncat > \"$TMPDIR/t.csv\"\necho \"{\\\"path\\\": \\\"$TMPDIR/t.csv\\\"}\"\n".utf8)

    private func temp() -> (PackageStore, URL) {
        let name = "lasso-folder-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            .appending(path: "Packages", directoryHint: .isDirectory)
        return (PackageStore(root: root, defaults: UserDefaults(suiteName: name)!), root.deletingLastPathComponent())
    }

    @Test func aScriptPackageNeedsItsFolder() {
        let (store, dir) = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: PackageStore.InstallError.self) { try store.install(Data(Self.manifest.utf8), origin: .pasted) }
        #expect(throws: PackageStore.InstallError.self) {
            try store.install(Data(Self.manifest.utf8), files: ["scripts/to-csv.sh": Data("echo no shebang".utf8)], origin: .file)
        }
    }

    @Test func scriptsInstallRunAndAChangeOnDiskTurnsItOff() async throws {
        let (store, dir) = temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: PackageScript.workspace("table-to-csv")) }
        try store.install(Data(Self.manifest.utf8), files: ["scripts/to-csv.sh": Self.script, "README.md": Data("Hi".utf8)], origin: .file)
        let item = try #require(store.installed.first)
        #expect(item.enabled && !item.changedOnDisk)
        #expect(FileManager.default.isExecutableFile(atPath: store.folder("table-to-csv").appending(path: "scripts/to-csv.sh").path))

        // It runs, sandboxed, and its file lands in the workspace.
        let entry = try #require(PackageRegistry.shared.all.first { $0.package.id == "table-to-csv" })
        let result = try await PackageCommandRunner.run(entry, entry.package.commands[0], input: PackageInput(text: "a,b"))
        guard case .file(let url) = result else { Issue.record("not a file"); return }
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""text":"a,b""#))

        // Full access: kept through an update that leaves the scripts alone, dropped when one changes.
        store.setFullAccess("table-to-csv", true)
        let v2 = Self.manifest.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.0.1\"")
        try store.install(Data(v2.utf8), files: ["scripts/to-csv.sh": Self.script, "README.md": Data("Hi".utf8)], origin: .file)
        #expect(store.hasFullAccess("table-to-csv"))
        let v3 = Self.manifest.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.0.2\"")
        try store.install(Data(v3.utf8), files: ["scripts/to-csv.sh": Self.script + Data("# changed\n".utf8)], origin: .file)
        #expect(!store.hasFullAccess("table-to-csv"))
        #expect(!FileManager.default.fileExists(atPath: store.folder("table-to-csv").appending(path: "README.md").path))

        // A script edited on disk turns the package off until reviewed.
        try Data("#!/bin/sh\ncurl evil\n".utf8).write(to: store.folder("table-to-csv").appending(path: "scripts/to-csv.sh"))
        store.reload()
        #expect(store.installed.first?.changedOnDisk == true)
        #expect(store.installed.first?.enabled == false)
        store.setEnabled("table-to-csv", true)
        #expect(store.installed.first?.enabled == false)

        // Removing deletes its data folder.
        try FileManager.default.createDirectory(at: store.dataRoot.appending(path: "table-to-csv"), withIntermediateDirectories: true)
        store.remove("table-to-csv")
        #expect(!FileManager.default.fileExists(atPath: store.dataRoot.appending(path: "table-to-csv").path))
        #expect(!FileManager.default.fileExists(atPath: store.folder("table-to-csv").path))
    }

    @Test func requirementsAreCheckedNeverInstalled() async throws {
        let package = try #require(PackageValidator.validate(Data("""
            {"lasso": 1, "id": "needs-things", "version": "1.0.0", "name": "Needs", "summary": "x", "author": "Me",
             "requires": [{"command": "sh"}, {"command": "lasso-no-such-tool", "install": "brew install lasso-no-such-tool"}],
             "patches": [{"target": "action.ai.ask.title", "set": "Ask"}]}
            """.utf8)).package)
        #expect(await PackageRequirements.missing(package) == "Needs lasso-no-such-tool. Install it with: brew install lasso-no-such-tool")
        #expect(PackageRequirements.missingNow(package) == "Needs lasso-no-such-tool. Install it with: brew install lasso-no-such-tool")
        var met = package
        met.requires = [.command("sh", install: nil), .app("com.apple.finder")]
        #expect(await PackageRequirements.missing(met) == nil)
    }

    @Test func theSpecsExamplesAreValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/PACKAGES.md")
        let spec = try String(contentsOf: url, encoding: .utf8)
        let blocks = spec.components(separatedBy: "```json\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
            .filter { $0.hasPrefix("{\n  \"lasso\": 1") && !$0.contains("\"...\"") }   // whole packages, not shortened ones
        #expect(blocks.count >= 7)
        for block in blocks {
            let outcome = PackageValidator.validate(Data(block.utf8))
            #expect(outcome.package != nil, "\(outcome.problems)\n\(block.prefix(100))")
        }
    }
}
