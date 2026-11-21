import Testing
import Foundation
import Security
@testable import Lasso

/// Every saved key lives in one Keychain item (the vault). Lasso's self-signed certificate has no Team
/// ID, so macOS locks each item to the build that saved it, and after an update every item asked for
/// the password separately. The old test here checked only that an item's access list was open to any
/// app, which was true while the prompts went on: the lock is the item's partition list. So these check
/// what actually decides the prompts: how many items there are.
@Suite(.serialized)
struct KeychainTests {
    private let account = "tests.keychain.\(UUID().uuidString.prefix(8))"
    private var service: String { Keychain.service }

    /// Every Lasso item in the login Keychain whose account is in `accounts`, plus the vault.
    private func items(_ accounts: [String]) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let list = result as? [[String: Any]] else { return [] }
        let names = list.compactMap { $0[kSecAttrAccount as String] as? String }
        return names.filter { accounts.contains($0) || $0 == Keychain.vaultAccount }
    }

    @Test func manyKeysAreOneItem() {
        let keys = (0..<5).map { "\(account).\($0)" }
        defer { keys.forEach(Keychain.delete) }
        for (i, key) in keys.enumerated() { Keychain.set("sk-\(i)", for: key) }
        #expect(items(keys) == [Keychain.vaultAccount], "each key became its own item, so each would ask after an update")
        // Read back from the Keychain, not the in-memory copy.
        Keychain.resetCache()
        #expect(keys.enumerated().allSatisfy { Keychain.get($0.element) == "sk-\($0.offset)" })
        #expect(Keychain.isReadableByAnyApp(Keychain.vaultAccount))
        Keychain.delete(keys[0])
        Keychain.resetCache()
        #expect(Keychain.get(keys[0]) == nil && Keychain.get(keys[1]) == "sk-1")
    }

    @Test func aKeyFromAnOlderVersionMovesIntoTheVault() {
        defer { Keychain.delete(account) }
        // How 0.17 and earlier saved it: an item of its own.
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecValueData as String: Data("sk-old".utf8)]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        #expect(items([account]).contains(account))
        #expect(Keychain.get(account) == "sk-old")
        #expect(!items([account]).contains(account), "the old item should be gone once moved")
        Keychain.resetCache()
        #expect(Keychain.get(account) == "sk-old")
    }

    /// The full test run hung for hours: `delete` on a background thread held the Keychain lock while
    /// removing a UserDefaults value, whose change notification waited on the main thread, and the main
    /// thread was drawing the chat header, waiting in `get` for that lock. Same shape here: an observer
    /// that hops to the main thread and reads a key. Before the fix this deadlocks and times out.
    @Test func deletingOffTheMainThreadDoesNotDeadlockAReader() async {
        let key = "\(account).deadlock"
        Keychain.set("x", for: key)
        final class Armed: @unchecked Sendable { var on = true }
        let armed = Armed()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: nil, queue: nil) { _ in
            guard armed.on, !Thread.isMainThread else { return }
            DispatchQueue.main.sync { _ = Keychain.get("\(key).other") }
        }
        defer { armed.on = false; NotificationCenter.default.removeObserver(observer) }
        let finished: Bool = await withCheckedContinuation { done in
            let gate = DispatchSemaphore(value: 0)
            Thread.detachNewThread { Keychain.delete(key); gate.signal() }
            DispatchQueue.global().async { done.resume(returning: gate.wait(timeout: .now() + 5) == .success) }
        }
        #expect(finished, "delete deadlocked with a reader on the main thread")
    }

    @Test func emptyMeansDeleted() {
        Keychain.set("x", for: account)
        Keychain.set("", for: account)
        Keychain.resetCache()
        #expect(Keychain.get(account) == nil)
    }
}
