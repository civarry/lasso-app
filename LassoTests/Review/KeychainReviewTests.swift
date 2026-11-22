import Foundation
import Testing
@testable import Lasso

/// QA review of the "declined Keychain prompt" fix (3b51bd2). Each test is a problem the review found
/// and fails because of it. Refusals are simulated with `Keychain.vaultReadsForTesting`; every vault is
/// the tests' own (`lasso.vault.tests`), never this Mac's.
@MainActor
@Suite(.serialized)
struct KeychainReviewTests {

    /// Runs `body` with the vault's first `refusals` reads refused, from a fresh launch's state.
    private func afterRefusal<T>(_ refusals: Int, _ body: (Keychain.VaultReadsForTesting) throws -> T) rethrows -> T {
        Keychain.resetCache()
        defer { Keychain.resetCache() }
        let reads = Keychain.VaultReadsForTesting(refusals: refusals)
        return try Keychain.$vaultReadsForTesting.withValue(reads) { try body(reads) }
    }

    private func tempStore() -> (PackageStore, UserDefaults, URL) {
        let name = "lasso-tests-review-\(UUID().uuidString.prefix(6))"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        return (PackageStore(root: root, defaults: defaults), defaults, root)
    }

    private func manifest(id: String) -> Data {
        Data(PackageValidatorTests.search
            .replacingOccurrences(of: "\"id\": \"brave-search\"", with: "\"id\": \"\(id)\"").utf8)
    }

    // R1. PackageMigration.run (launch, background) ignores `setValue`'s Bool and calls `deleteKey`,
    //     whose default removes the old UserDefaults copy. `getMigrating` returns that copy while the
    //     vault is refused, so the only copy of the Tavily/SerpApi key is deleted, and `doneKey` is set,
    //     so it never runs again. It also prompts in the background (set and delete both retry).
    @Test func migrationKeepsTheOldKeyWhenThePackageSecretWasntSaved() throws {
        let (store, defaults, root) = tempStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            for id in BundledPackages.ids { Keychain.delete("package.\(id).key") }
            PackageStore.shared.reload()
        }
        // What `Keychain.getMigrating` returns while refused: the legacy copy, kept in UserDefaults.
        var legacy = ["tavily.apiKey": "tvly-only-copy"]
        var deleted: [String] = []
        let reads = afterRefusal(100) { reads in
            _ = Keychain.get("qa-review.any")   // the launch's background read: prompt cancelled
            PackageMigration.run(store: store, defaults: defaults,
                                 readKey: { legacy[$0] },
                                 deleteKey: { deleted.append($0); legacy[$0] = nil })
            return reads.count
        }
        #expect(deleted.isEmpty, "the old key was deleted though its package secret was never saved: \(deleted)")
        #expect(!defaults.bool(forKey: PackageMigration.doneKey), "migration marked done with the key unsaved; it never retries")
        #expect(reads == 1, "a launch-time migration prompted again in the background: \(reads) vault reads")
    }

    // R2. PackageSettingRow (PackagesSettings.swift:1506-1507, 1581-1585) loads `text` on appear and
    //     commits on disappear when `text != store.value`. Loaded while refused, an untouched secret
    //     row holds "". Once any save unlocks the vault (Try again on another row, Settings' Try again),
    //     leaving the page commits "" and deletes the real key. The row's logic is replayed verbatim.
    @Test func anUntouchedPackageSecretLoadedWhileRefusedSurvivesAnUnlock() throws {
        let (store, _, root) = tempStore()
        let id = "qa-review-\(UUID().uuidString.prefix(6).lowercased())"
        let other = "qa-review.other.\(UUID().uuidString)"
        defer {
            if let p = store.installed.first(where: { $0.id == id })?.package, let s = p.setting("key") {
                Keychain.delete(store.secretAccount(id, s.id))
            }
            Keychain.delete(other)
            try? FileManager.default.removeItem(at: root)
            PackageStore.shared.reload()
        }
        let package = try store.install(manifest(id: id), origin: .file)
        let setting = try #require(package.setting("key"))
        #expect(store.setValue("sk-real", id, setting), "precondition")

        afterRefusal(1) { _ in
            var text = ""
            text = store.value(id, setting)                 // .onAppear, vault refused: ""
            #expect(text == "", "precondition: loaded while refused")
            #expect(Keychain.set("sk-other", for: other), "precondition: the user's save unlocks the vault")
            // .onDisappear { commit() }, verbatim:
            if text != store.value(id, setting) { _ = store.setValue(text, id, setting) }
        }
        #expect(store.value(id, setting) == "sk-real",
                "leaving the page deleted a package key the user never touched")
    }

    // R3. PackageStore.remove (PackageStore.swift:384-387) calls `Keychain.delete` (retry on) once per
    //     version it finds, ignoring the result: several prompts in a row on one uninstall, then the
    //     secret stays in the vault, silently, and a reinstall with this id doesn't start empty.
    @Test func uninstallWithARefusedVaultAsksOnceAndSaysSo() throws {
        let (store, _, root) = tempStore()
        let id = "qa-review-\(UUID().uuidString.prefix(6).lowercased())"
        let account = store.secretAccount(id, "key")
        defer { Keychain.delete(account); try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        let package = try store.install(manifest(id: id), origin: .file)
        #expect(store.setValue("sk-pkg", id, try #require(package.setting("key"))), "precondition")

        let reads = afterRefusal(100) { reads in
            _ = Keychain.get("qa-review.any")   // refused at launch
            store.remove(id)
            return reads.count
        }
        #expect(reads <= 2, "one uninstall prompted \(reads - 1) times after the launch's refusal")
        #expect(Keychain.get(account) == nil, "the uninstalled package's key is still saved; a reinstall gets it back")
    }

    // R4. The hook is task-local, but what it causes (`refused`, a reset `cache`) is global. Suites run
    //     in parallel (KeychainTests, PackageEngineTests are not serialized with AppShellRegressionTests),
    //     so a test alongside reads nil for a key that is saved: the Keychain tests can flake.
    @Test func aSimulatedRefusalDoesNotLeakIntoOtherTasks() async throws {
        let account = "qa-review.leak.\(UUID().uuidString)"
        Keychain.resetCache()
        #expect(Keychain.set("sk-saved", for: account), "precondition")
        defer { Keychain.resetCache(); Keychain.delete(account) }
        Keychain.resetCache()
        let reads = Keychain.VaultReadsForTesting(refusals: 1)
        let seenAlongside: String? = await Keychain.$vaultReadsForTesting.withValue(reads) {
            _ = Keychain.get("qa-review.any")   // this test's simulated refusal
            return await Task.detached { Keychain.get(account) }.value   // another test, no hook
        }
        #expect(seenAlongside == "sk-saved", "a test without the hook read nil for a saved key: the simulated refusal leaked")
    }
}
