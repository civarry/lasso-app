import Foundation
import Security

/// Minimal Keychain wrapper for API keys (encrypted at rest, unlike UserDefaults). Items are scoped
/// to the app's bundle id and stored as generic passwords keyed by `account`.
///
/// Items are readable by any app of this user without a prompt. Lasso is signed with a self-signed
/// certificate, which has no Apple Team ID, so macOS can only tie a restricted item to one exact build
/// (`cdhash:` in its partition list): every update asked for the login password once per saved key.
/// The values stay encrypted in the login Keychain; what's given up is the per-app prompt, the same
/// trade a CLI tool's key file makes. (The data-protection Keychain would avoid it, but needs a Team ID:
/// errSecMissingEntitlement.) Items saved by older versions are re-saved this way the first time
/// they're read, which asks once more, for the last time.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.cjcarito.Lasso" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        if !isOpen(account) { add(string, for: account) }   // the one-time move to the open ACL
        return string
    }

    static func set(_ value: String, for account: String) {
        guard !value.isEmpty else { delete(account); return }
        add(value, for: account)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: openKey(account))
    }

    /// Replaces the item with one any app of this user can read (see the type's note). Delete and add
    /// rather than update: an update keeps the old, build-locked access list.
    private static func add(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        if let access = openAccess(label: account) { item[kSecAttrAccess as String] = access }
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.set(true, forKey: openKey(account))
        } else {
            // Never lose the key: save it the default way (it then asks again after an update).
            item[kSecAttrAccess as String] = nil
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// An access list whose decrypt permission has no application list, i.e. any application. (A nil
    /// trusted list in `SecAccessCreate` means the calling app only, so it's cleared afterwards.)
    private static func openAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess, let access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL],
              !acls.isEmpty else { return nil }
        for acl in acls {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess,
                  SecACLSetContents(acl, nil, description ?? label as CFString, prompt) == errSecSuccess else { return nil }
        }
        return access
    }

    private static func openKey(_ account: String) -> String { "keychain.open.\(account)" }
    private static func isOpen(_ account: String) -> Bool { UserDefaults.standard.bool(forKey: openKey(account)) }

    /// Whether the saved item's decrypt permission is open to any application (for tests).
    static func isReadableByAnyApp(_ account: String) -> Bool {
        var request = query(account)
        request[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &ref) == errSecSuccess, let ref else { return false }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(ref as! SecKeychainItem, &access) == errSecSuccess, let access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return false }
        return acls.contains { acl in
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            return SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess && apps == nil
        }
    }

    /// Read a value, migrating it once from a legacy `UserDefaults` key into the Keychain.
    static func getMigrating(_ account: String, legacyDefaultsKey: String) -> String? {
        if let value = get(account) { return value }
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            set(legacy, for: account)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return legacy
        }
        return nil
    }
}
