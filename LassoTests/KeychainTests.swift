import Testing
import Foundation
import Security
@testable import Lasso

/// Saved keys must be readable by the next build without a password prompt: Lasso's self-signed
/// certificate has no Team ID, so a build-locked item asked once per key after every update.
@Suite(.serialized)
struct KeychainTests {
    private let account = "tests.keychain.\(UUID().uuidString.prefix(8))"

    @Test func savedKeysAreOpenToTheNextBuild() {
        defer { Keychain.delete(account) }
        Keychain.set("sk-test", for: account)
        #expect(Keychain.get(account) == "sk-test")
        #expect(Keychain.isReadableByAnyApp(account))
    }

    @Test func aKeyFromAnOlderVersionIsMovedOnFirstRead() {
        defer { Keychain.delete(account) }
        // How 0.16.1 and earlier saved it: the default, build-locked access list.
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.cjcarito.Lasso",
                                   kSecAttrAccount as String: account,
                                   kSecValueData as String: Data("sk-old".utf8)]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        #expect(!Keychain.isReadableByAnyApp(account))
        #expect(Keychain.get(account) == "sk-old")
        #expect(Keychain.isReadableByAnyApp(account))
        #expect(Keychain.get(account) == "sk-old")
    }
}
