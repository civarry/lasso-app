import Foundation
import Testing
@testable import Lasso

/// Third QA review of the "declined Keychain prompt" fix (4f3fb70). Each test is a problem the review
/// found and fails because of it. Refusals are simulated with `Keychain.vaultReadsForTesting`, each with
/// its own launch state; every vault is the tests' own (`lasso.vault.tests`), never this Mac's.
@MainActor
@Suite(.serialized)
struct Keychain3ReviewTests {

    /// Runs `body` as a fresh launch whose first `refusals` vault reads are refused.
    private func launch<T>(refusals: Int, _ body: (Keychain.VaultReadsForTesting) throws -> T) rethrows -> T {
        let reads = Keychain.VaultReadsForTesting(refusals: refusals)
        return try Keychain.$vaultReadsForTesting.withValue(reads) { try body(reads) }
    }

    private func suite() -> (UserDefaults, String) {
        let name = "lasso-tests-review3-\(UUID().uuidString.prefix(6))"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lasso-tests-review3-\(UUID().uuidString.prefix(6))",
                                                         directoryHint: .isDirectory)
    }

    private func manifest(id: String) -> Data {
        Data(PackageValidatorTests.search
            .replacingOccurrences(of: "\"id\": \"brave-search\"", with: "\"id\": \"\(id)\"").utf8)
    }

    // C1. The fresh-install clear (PackageStore.swift:331-334) calls `removeAll(retryIfRefused: false)`
    //     and ignores the result. The uninstall alert (PackagesSettings.swift:1482) tells the user
    //     "Installing it again starts without it", but the likeliest reinstall is in the same launch,
    //     where the vault is still refused: the clear does nothing, silently. The next launch the vault
    //     opens and the reinstalled package (possibly a different author's, same id) has the old key.
    //     Rewritten after this review: the fresh-install clear is gone (C2 shows it deleted another
    //     build's key) and uninstall is all or nothing instead, so a refused uninstall no longer leaves a
    //     half-removed package to reinstall. The requirement is unchanged: no package ever gets a key an
    //     uninstall left behind. Checked as the user meets it: the refused uninstall says so and changes
    //     nothing, and once the vault opens it goes through and a reinstall starts empty.
    @Test func aReinstallInTheSameRefusedLaunchStillStartsEmpty() throws {
        let (defaults, _) = suite()
        let root = tempRoot()
        let store = PackageStore(root: root, defaults: defaults)
        let id = "qa3-\(UUID().uuidString.prefix(6).lowercased())"
        let account = store.secretAccount(id, "key")
        defer { Keychain.delete(account); try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }

        let package = try launch(refusals: 0) { _ in try store.install(manifest(id: id), origin: .file) }
        let setting = try #require(package.setting("key"))
        #expect(launch(refusals: 0) { _ in store.setValue("sk-old", id, setting) }, "precondition")
        let folder = root.appending(path: id, directoryHint: .isDirectory)

        launch(refusals: 100) { _ in
            _ = Keychain.get("qa3.any")   // the launch's background read: prompt cancelled
            // (a) The uninstall says it didn't happen.
            #expect(!store.remove(id), "a refused uninstall claimed it was done")
        }
        // (b) Nothing half-removed: still installed, files and record together, key still there.
        #expect(store.isInstalled(id), "a refused uninstall removed the package anyway")
        #expect(FileManager.default.fileExists(atPath: folder.path), "its files went though the uninstall stopped")
        #expect(launch(refusals: 0) { _ in Keychain.get(account) } == "sk-old", "its key went though the uninstall stopped")

        // (c) Once the vault opens the uninstall goes through, and a reinstall starts empty.
        Keychain.resetCache()
        try launch(refusals: 0) { _ in
            #expect(store.remove(id), "the uninstall failed with the vault open")
            #expect(!store.isInstalled(id) && !FileManager.default.fileExists(atPath: folder.path))
            let again = try store.install(manifest(id: id), origin: .file)
            #expect(store.value(id, try #require(again.setting("key"))) == "",
                    "a reinstall after the uninstall got the old key back")
        }
    }

    // C2. The fresh-install clear keys off `records[id] == nil`, but records live in UserDefaults and
    //     the vault is shared across builds with their own UserDefaults (Keychain.swift:17: the Xcode
    //     build, com.cjcarito.Lasso.dev, uses the installed app's saved keys; DevSettingsImport copies
    //     the records once only). Packages live in one folder for both. A package installed in one
    //     build after that copy is invisible to the other (no record: PackageStore.swift:204), so the
    //     user installs it there too, and that "fresh install" deletes the key the first build is
    //     using. Before 4f3fb70 install never touched keys.
    @Test func installingInAnotherBuildDoesNotDeleteTheKeyItUses() throws {
        let (releaseDefaults, _) = suite()
        let (devDefaults, _) = suite()
        let root = tempRoot()   // one Packages folder, as for both builds
        let release = PackageStore(root: root, defaults: releaseDefaults)
        let dev = PackageStore(root: root, defaults: devDefaults)
        let id = "qa3-\(UUID().uuidString.prefix(6).lowercased())"
        let account = release.secretAccount(id, "key")
        defer { Keychain.delete(account); try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }

        try launch(refusals: 0) { _ in
            let package = try release.install(manifest(id: id), origin: .catalog)
            #expect(release.setValue("sk-in-use", id, try #require(package.setting("key"))), "precondition")
        }
        #expect(!dev.isInstalled(id), "precondition: the other build doesn't see it (no record)")
        try launch(refusals: 0) { _ in _ = try dev.install(manifest(id: id), origin: .catalog) }

        let seen = launch(refusals: 0) { _ in Keychain.get(account) }
        #expect(seen == "sk-in-use", "installing in the other build deleted the key the installed build uses")
    }
}
