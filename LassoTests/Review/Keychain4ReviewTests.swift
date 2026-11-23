import Foundation
import Testing
@testable import Lasso

/// Fourth QA review of the "declined Keychain prompt" fix (ca50bf8). Refusals are simulated with
/// `Keychain.vaultReadsForTesting`; every vault is the tests' own, never this Mac's.
@MainActor
@Suite(.serialized)
struct Keychain4ReviewTests {

    private func launch<T>(refusals: Int, _ body: (Keychain.VaultReadsForTesting) throws -> T) rethrows -> T {
        let reads = Keychain.VaultReadsForTesting(refusals: refusals)
        return try Keychain.$vaultReadsForTesting.withValue(reads) { try body(reads) }
    }

    private func makeStore() -> (PackageStore, URL) {
        let defaults = UserDefaults(suiteName: "lasso-tests-review4-\(UUID().uuidString.prefix(6))")!
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lasso-tests-review4-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        return (PackageStore(root: root, defaults: defaults), root)
    }

    /// The search fixture with this id and version; `secret` names its one secret setting.
    private func manifest(id: String, version: String, secret: String = "key") -> Data {
        Data(PackageValidatorTests.search
            .replacingOccurrences(of: "\"id\": \"brave-search\"", with: "\"id\": \"\(id)\"")
            .replacingOccurrences(of: "\"version\": \"1.0.0\"", with: "\"version\": \"\(version)\"")
            .replacingOccurrences(of: "{\"id\": \"key\"", with: "{\"id\": \"\(secret)\"")
            .replacingOccurrences(of: "{{settings.key}}", with: "{{settings.\(secret)}}").utf8)
    }

    /// The same package with no settings at all.
    private func keyless(id: String) -> Data {
        Data(PackageValidatorTests.search
            .replacingOccurrences(of: "\"id\": \"brave-search\"", with: "\"id\": \"\(id)\"")
            .replacingOccurrences(of: "\"settings\": [{\"id\": \"key\", \"label\": \"API key\", \"kind\": \"secret\"}],", with: "")
            .replacingOccurrences(of: ",\\s*\"headers\": \\{\"X-Subscription-Token\": \"\\{\\{settings.key\\}\\}\"\\}",
                                  with: "", options: .regularExpression).utf8)
    }

    // D1. `remove` finds the keys to delete from the versions it can still read: current, approved,
    //     on disk, and the one kept for Go back (PackageStore.swift:382-390). A secret that two updates
    //     ago stopped being declared is in none of them, so it survives the uninstall. Until ca50bf8 the
    //     fresh-install clear caught it on reinstall; ca50bf8 removed that clear, so the next package
    //     with this id (from any author) gets the old key. The doc comment at :377 promises "no later
    //     package with this id ever finds an old key".
    @Test func aSecretTwoUpdatesOldIsRemovedWithThePackage() throws {
        let (store, root) = makeStore()
        let id = "qa4-\(UUID().uuidString.prefix(6).lowercased())"
        let old = store.secretAccount(id, "key")
        defer {
            launch(refusals: 0) { _ in _ = Keychain.removeAll([old, store.secretAccount(id, "token")]) }
            try? FileManager.default.removeItem(at: root); PackageStore.shared.reload()
        }
        try launch(refusals: 0) { _ in
            let v1 = try store.install(manifest(id: id, version: "1.0.0"), origin: .catalog)
            #expect(store.setValue("sk-old", id, try #require(v1.setting("key"))), "precondition")
            _ = try store.install(manifest(id: id, version: "2.0.0", secret: "token"), origin: .catalog)
            _ = try store.install(manifest(id: id, version: "3.0.0", secret: "token"), origin: .catalog)
            #expect(store.remove(id), "precondition: the uninstall went through")
            #expect(Keychain.get(old) == nil, "the uninstall left a key its package once declared")
            let again = try store.install(manifest(id: id, version: "1.0.0"), origin: .file)
            #expect(store.value(id, try #require(again.setting("key"))) == "",
                    "a later package with this id got the old key back")
        }
    }

    // Check for question 2 (expected to pass): a package with no keys uninstalls even while the saved
    // keys are refused, and without asking.
    @Test func aKeylessPackageUninstallsWhileRefusedWithoutAsking() throws {
        let (store, root) = makeStore()
        let id = "qa4-\(UUID().uuidString.prefix(6).lowercased())"
        defer { try? FileManager.default.removeItem(at: root); PackageStore.shared.reload() }
        let package = try launch(refusals: 0) { _ in try store.install(keyless(id: id), origin: .file) }
        #expect(package.settings.isEmpty, "precondition")
        let (removed, reads) = launch(refusals: 100) { reads in
            _ = Keychain.get("qa4.any")   // the launch's background read: refused
            let before = reads.count
            return (store.remove(id), reads.count - before)
        }
        #expect(removed, "a package with no keys couldn't be uninstalled while the vault is refused")
        #expect(reads == 0, "uninstalling a keyless package prompted")
        #expect(!store.isInstalled(id))
    }
}
