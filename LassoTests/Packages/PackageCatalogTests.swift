import Foundation
import Testing
@testable import Lasso

/// Build step 6: the catalog's index and downloads, `.lassopkg` bundles, starters, `lasso://` links
/// and Developer mode (spec, "The catalog", "Building a package", "Only a person installs").
@MainActor
@Suite(.serialized)
struct PackageCatalogTests {
    static func bundle(_ id: String = "study-tools") throws -> Data {
        let files = PackageStarters.files(.script, id: id)
        let manifest = Data(files["lasso.json"]!.utf8)
        var rest: PackageFiles.Files = [:]
        for (path, text) in files where path != "lasso.json" { rest[path] = Data(text.utf8) }
        return try PackageBundle.pack(manifest: manifest, files: rest)
    }

    static func index(sha: String, host: String = "raw.githubusercontent.com") -> Data {
        Data("""
        {"lasso": 1, "packages": [
          {"id": "study-tools", "version": "1.2.0", "name": "Study tools", "summary": "Explain simply.", "author": "Lasso",
           "url": "https://\(host)/civarry/lasso-packages/main/dist/study-tools-1.2.0.lassopkg", "sha256": "\(sha)",
           "commands": [{"title": "Explain", "surfaces": ["toolbar"]}], "permissions": {"hosts": [], "script": true}},
          {"id": "Bad Id", "version": "1.0.0", "name": "x", "url": "https://raw.githubusercontent.com/x", "sha256": "0"}
        ]}
        """.utf8)
    }

    @Test func theIndexIsReadAndOnlyTheCatalogsHostIsTrusted() throws {
        let entries = try PackageCatalog.parse(Self.index(sha: "abc"))
        #expect(entries.map(\.id) == ["study-tools"])
        #expect(entries[0].tags == ["Runs code", "Stays on your Mac"])
        #expect(try PackageCatalog.parse(Self.index(sha: "abc", host: "evil.example.com")).isEmpty)
        #expect(throws: PackageCatalog.LoadError.unreadable) { try PackageCatalog.parse(Data("[]".utf8)) }
    }

    @Test func aDownloadThatDoesntMatchTheIndexIsRefused() throws {
        let data = try Self.bundle()
        let entry = try #require(try PackageCatalog.parse(Self.index(sha: PackageFiles.sha256(data))).first)
        let unpacked = try PackageCatalog.verify(data, entry)
        #expect(unpacked.files["scripts/count.py"] != nil)
        var tampered = data
        tampered.append(contentsOf: Array(" ".utf8))
        #expect(throws: PackageCatalog.LoadError.hashMismatch) { try PackageCatalog.verify(tampered, entry) }
    }

    @Test func bundlesRoundTripAndRefuseEscapingPaths() throws {
        let unpacked = try #require(PackageBundle.unpack(try Self.bundle()))
        #expect(PackageValidator.validate(unpacked.manifest).package?.id == "study-tools")
        for bad in ["../evil.sh", "/etc/x", "scripts//x", "lasso.json"] {
            let data = Data(#"{"lassopkg": 1, "manifest": "e30=", "files": {"\#(bad)": "eA=="}}"#.utf8)
            #expect(PackageBundle.unpack(data) == nil, "\(bad)")
        }
    }

    @Test func theCatalogIsntReadInLocalOnlyMode() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(body: Self.index(sha: "abc")))
        let catalog = PackageCatalog(indexURL: URL(string: "\(server.base)/index.json")!)
        await catalog.refresh(localOnly: true)
        #expect(server.requests.isEmpty)
        #expect(catalog.entries.isEmpty)
        await catalog.refresh(localOnly: false)
        #expect(server.requests.count == 1)
        #expect(catalog.entries.map(\.id) == ["study-tools"])
        await #expect(throws: PackageCatalog.LoadError.localOnly) { try await catalog.download(catalog.entries[0], localOnly: true) }
    }

    @Test func updatesAreNewerCatalogVersions() async throws {
        let name = "lasso-catalog-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory).appending(path: "Packages")
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let files = PackageStarters.files(.prompt, id: "study-tools")
        try store.install(Data(files["lasso.json"]!.utf8), origin: .catalog)
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(body: Self.index(sha: "abc")))
        let catalog = PackageCatalog(indexURL: URL(string: "\(server.base)/index.json")!)
        await catalog.refresh(localOnly: false)
        #expect(catalog.updates(store.installed).map(\.entry.version) == ["1.2.0"])
    }

    @Test func everyStarterIsAValidPackage() {
        for kind in PackageStarters.Kind.allCases {
            let files = PackageStarters.files(kind, id: "my-\(kind.rawValue)")
            let outcome = PackageValidator.validate(Data(files["lasso.json"]!.utf8))
            #expect(outcome.package != nil, "\(kind): \(outcome.problems)")
            var rest: PackageFiles.Files = [:]
            for (path, text) in files where path != "lasso.json" { rest[path] = Data(text.utf8) }
            if let package = outcome.package { #expect(PackageFiles.problems(package, rest).isEmpty, "\(kind)") }
        }
    }

    @Test func aLinkOnlyOpensBrowse() {
        let before = PackageStore.shared.installed.map(\.id)
        let pane = UserDefaults.standard.object(forKey: SettingsView.paneKey)
        defer {
            PackageCatalog.shared.requested = nil
            UserDefaults.standard.set(pane, forKey: SettingsView.paneKey)
        }
        #expect(PackageLinks.handle(URL(string: "lasso://install?id=study-tools")!))
        #expect(PackageCatalog.shared.requested == "study-tools")
        #expect(PackageStore.shared.installed.map(\.id) == before)
        #expect(!PackageLinks.handle(URL(string: "lasso://install?id=../../x")!))
        #expect(!PackageLinks.handle(URL(string: "lasso://fullaccess?id=study-tools")!))
        #expect(!PackageLinks.handle(URL(string: "https://install?id=study-tools")!))
    }

    @Test func aDeveloperFolderReloadsAndKeepsTheLastGoodCopy() throws {
        let name = "lasso-dev-\(UUID().uuidString.prefix(6))"
        let base = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let store = PackageStore(root: base.appending(path: "Packages"), defaults: UserDefaults(suiteName: name)!)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appending(path: "my-tool", directoryHint: .isDirectory)
        try PackageStarters.write(.script, id: "my-tool", to: folder)
        try store.loadDeveloper(folder)
        #expect(store.installed.first?.origin == .developer)
        #expect(store.developerSource("my-tool")?.lastPathComponent == "my-tool")

        // Saved with the same version: it reloads anyway (it's the user's own folder).
        let manifest = folder.appending(path: "lasso.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.replacingOccurrences(of: "Count words", with: "Word count").write(to: manifest, atomically: true, encoding: .utf8)
        store.reloadChangedDeveloperFolders()
        #expect(store.installed.first?.package.commands.first?.title == "Word count")
        #expect(store.developerProblems["my-tool"] == nil)

        // A mistake keeps the last good copy running and says what's wrong.
        try text.replacingOccurrences(of: "\"output\": \"markdown\"", with: "\"output\": \"nope\"").write(to: manifest, atomically: true, encoding: .utf8)
        store.reloadChangedDeveloperFolders()
        #expect(store.installed.first?.package.commands.first?.title == "Word count")
        #expect(store.developerProblems["my-tool"]?.contains { $0.message.contains("Unknown output") } == true)
    }
}

/// The real catalog (`civarry/lasso-packages`): read the index, download every package, check its hash
/// and review it as Lasso would before Add. Opt-in: `TEST_RUNNER_LASSO_PACKAGES_LIVE=1`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_PACKAGES_LIVE"] == "1"))
struct PackageCatalogLiveTests {
    @Test func everyCatalogPackageDownloadsAndPassesTheReview() async throws {
        let catalog = PackageCatalog()
        await catalog.refresh(localOnly: false)
        #expect(catalog.state == .loaded)
        #expect(catalog.entries.count >= 7)
        let name = "lasso-live-catalog-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory).appending(path: "Packages")
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for entry in catalog.entries {
            let package = try await catalog.download(entry, localOnly: false)
            guard case .success(let reviewed) = store.review(package.manifest, files: package.files) else {
                Issue.record("\(entry.id) didn't pass the review"); continue
            }
            #expect(reviewed.package.id == entry.id && reviewed.package.version == entry.version)
        }
    }
}
