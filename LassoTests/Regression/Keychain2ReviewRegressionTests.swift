import Foundation
import Testing
@testable import Lasso

/// Second QA review of the "declined Keychain prompt" fix (0766089). Each test is a problem the review
/// found and fails because of it. Refusals are simulated with `Keychain.vaultReadsForTesting`, each with
/// its own launch state; every vault is the tests' own (`lasso.vault.tests`), never this Mac's.
@MainActor
@Suite(.serialized)
struct Keychain2ReviewTests {

    /// Runs `body` as a fresh launch whose first `refusals` vault reads are refused.
    private func launch<T>(refusals: Int, _ body: (Keychain.VaultReadsForTesting) throws -> T) rethrows -> T {
        let reads = Keychain.VaultReadsForTesting(refusals: refusals)
        return try Keychain.$vaultReadsForTesting.withValue(reads) { try body(reads) }
    }

    private func tempStore() -> (PackageStore, UserDefaults, URL) {
        let name = "lasso-tests-review2-\(UUID().uuidString.prefix(6))"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        return (PackageStore(root: root, defaults: defaults), defaults, root)
    }

    // K1. PackageMigration.run (PackageMigration.swift:38-67) now leaves `doneKey` unset when the key
    //     didn't save, and on the next launch reinstalls any connector package that isn't installed
    //     (line 51: not installed -> install). Launch 1: the vault prompt is cancelled, Tavily is
    //     installed with an empty key, migration not done. The user removes the package. Launch 2:
    //     the vault opens, the migration installs Tavily again and saves the old key into it. A package
    //     the user uninstalled comes back, key and all.
    @Test func migrationDoesNotReinstallAPackageTheUserRemoved() throws {
        let (store, defaults, root) = tempStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            for id in BundledPackages.ids { Keychain.delete("package.\(id).key") }
            PackageStore.shared.reload()
        }
        var legacy = ["tavily.apiKey": "tvly-old"]   // the old connector's key, kept because it didn't move
        let read: (String) -> String? = { legacy[$0] }
        let delete: (String) -> Void = { legacy[$0] = nil }

        launch(refusals: 100) { _ in
            _ = Keychain.get("qa2.any")   // the launch's background read: prompt cancelled
            PackageMigration.run(store: store, defaults: defaults, readKey: read, deleteKey: delete)
        }
        #expect(store.isInstalled("tavily"), "precondition: launch 1 installed the package")
        #expect(!defaults.bool(forKey: PackageMigration.doneKey), "precondition: launch 1 isn't done")

        store.remove("tavily")   // the user doesn't want it
        #expect(!store.isInstalled("tavily"), "precondition")

        launch(refusals: 0) { _ in
            PackageMigration.run(store: store, defaults: defaults, readKey: read, deleteKey: delete)
        }
        #expect(!store.isInstalled("tavily"), "the next launch's migration reinstalled a package the user removed")
        #expect(Keychain.get("package.tavily.key") == nil, "and put the old key back into it")
    }

    // K3. PackageMigration.run (PackageMigration.swift:42) treats a nil key as "no key" and skips the
    //     connector without clearing `finished`. Since 0.18 the Tavily/SerpApi key lives in the vault,
    //     so on a launch whose prompt was cancelled `readKey` returns nil (unknown, not empty), and
    //     `doneKey` is set (line 67). The migration never runs again: the key stays orphaned under
    //     `tavily.apiKey` and the package is never installed. `readKey` here is the default
    //     (`getMigrating`) minus its UserDefaults step, so the test host's preferences aren't touched.
    @Test func migrationIsNotMarkedDoneWhenTheOldKeyCouldNotBeRead() throws {
        let (store, defaults, root) = tempStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            Keychain.delete("tavily.apiKey")
            for id in BundledPackages.ids { Keychain.delete("package.\(id).key") }
            PackageStore.shared.reload()
        }
        #expect(launch(refusals: 0) { _ in Keychain.set("tvly-in-vault", for: "tavily.apiKey") }, "precondition")

        launch(refusals: 100) { _ in
            _ = Keychain.get("qa2.any")   // the launch's background read: prompt cancelled
            PackageMigration.run(store: store, defaults: defaults,
                                 readKey: { Keychain.get($0) },
                                 deleteKey: { Keychain.delete($0, retryIfRefused: false) })
        }
        #expect(!defaults.bool(forKey: PackageMigration.doneKey),
                "migration marked done though the old key couldn't be read; it never moves the key")
    }

    // K2. Pending removals (Keychain.swift:242-250, 268-273) are a list of account names in this app's
    //     UserDefaults, replayed on every vault load with no check of what they were meant to remove.
    //     The vault is shared with a build that has its own UserDefaults (the Xcode build,
    //     com.cjcarito.Lasso.dev, uses the release app's saved keys: Keychain.swift:17). A package
    //     uninstalled in one build while refused, reinstalled with a new key in the other, loses that
    //     new key the next time the first build opens the vault. Simulated: the other build's `set`
    //     clears only its own list, so this build's list is put back as it was.
    @Test func aWaitingRemovalDoesNotDeleteAKeySavedSince() {
        // Design changed after this review: nothing is remembered for later, so no stale removal can run.
        // This guards against bringing a replay back: a removal refused now never deletes a later key.
        let account = "qa2.pending.\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        launch(refusals: 100) { _ in
            _ = Keychain.get("qa2.any")
            #expect(!Keychain.removeAll([account]), "precondition: the removal can't happen now")
        }
        Keychain.resetCache()
        // The other build reinstalls the package and saves its new key.
        #expect(launch(refusals: 0) { _ in Keychain.set("sk-reinstalled", for: account) }, "precondition")
        Keychain.resetCache()
        // This build's next launch opens the vault.
        let seen = launch(refusals: 0) { _ in Keychain.get(account) }
        #expect(seen == "sk-reinstalled", "a removal refused earlier deleted a key saved after it")
    }
}
