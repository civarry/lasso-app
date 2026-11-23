import Foundation
import Security

/// Lasso's saved keys (encrypted at rest, unlike UserDefaults), all in **one** Keychain item: the vault.
///
/// Why one item: Lasso is signed with a self-signed certificate, which has no Apple Team ID, so macOS
/// ties every item it saves to the exact build that saved it (`cdhash:` in the item's partition list,
/// checked even when the item's access list is open to any app). After each update every item asked
/// for the login password separately: 13 prompts for 13 keys. With one item there's one prompt per
/// update; "Always Allow" adds the new build and nothing else asks. (A stable Team ID would end the
/// prompts entirely, but a self-signed certificate never gets one, tested; the data-protection
/// Keychain needs one too: errSecMissingEntitlement.)
///
/// Keys saved by older versions, one item each, move into the vault the first time Lasso reads them,
/// which asks once more for each key actually used, for the last time.
enum Keychain {
    /// The installed app's ID, also for Xcode builds (`com.cjcarito.Lasso.dev`): they share its saved keys.
    static let service = "com.cjcarito.Lasso"

    /// Inside the unit-test host a Keychain dialog would hang the run (no one answers it), and a test
    /// build is a different app to macOS, so older items would ask. Tests never prompt: a read fails.
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let noPromptsUnderTests: Void = {
        if isTesting { SecKeychainSetUserInteractionAllowed(false) }
    }()

    /// The vault's account. Tests use their own, so they never touch (or need) the real one.
    static var vaultAccount: String { isTesting ? "lasso.vault.tests" : "lasso.vault" }

    private static let lock = NSRecursiveLock()

    /// What this launch knows about the vault. Guarded by `lock`. Tests that simulate a refusal get one
    /// of their own (`VaultReadsForTesting`), so a test running alongside still sees the real vault.
    final class LaunchState: @unchecked Sendable {
        /// The vault's contents once read (nil: not read yet, or couldn't be read).
        var cache: [String: String]?
        /// The vault couldn't be read (the prompt was cancelled): don't ask again on every key.
        var refused = false
        /// Accounts with no saved key, old or new: asked once per launch, not on every read (the chat
        /// header reads one each time it draws, and each old-item lookup is a Keychain query).
        var missing: Set<String> = []
    }
    private static let shared = LaunchState()

    /// Posted (on the main thread) when the vault opens after a refusal this launch: fields that showed
    /// a key as empty because it couldn't be read can read it now.
    static let didOpenAfterRefusal = Notification.Name("Keychain.didOpenAfterRefusal")

    private static func query(_ account: String) -> [String: Any] {
        _ = noPromptsUnderTests
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum VaultState: Equatable { case loaded([String: String]), missing, unreadable(OSStatus) }

    #if DEBUG
    /// Tests: one test's vault reads, counted, the first `refusals` of them refused as if the user
    /// cancelled the prompt. Task-local, and with its own `LaunchState`, so a test running alongside
    /// neither sees the refusals nor what they cause. Guarded by `lock`.
    final class VaultReadsForTesting: @unchecked Sendable {
        var refusals: Int
        var count = 0
        let state = LaunchState()
        init(refusals: Int) {
            self.refusals = refusals
            Keychain.lock.lock(); Keychain.liveHooks.add(self); Keychain.lock.unlock()
        }
    }
    @TaskLocal static var vaultReadsForTesting: VaultReadsForTesting?
    nonisolated(unsafe) private static let liveHooks = NSHashTable<VaultReadsForTesting>.weakObjects()   // guarded by `lock`
    #endif

    /// The state of the task asking: a test's own while it simulates a refusal, otherwise the launch's.
    private static var state: LaunchState {
        #if DEBUG
        if let reads = vaultReadsForTesting { return reads.state }
        #endif
        return shared
    }

    /// Every copy of the vault in memory (one, outside tests).
    private static var allStates: [LaunchState] {
        #if DEBUG
        return [shared] + liveHooks.allObjects.map(\.state)
        #else
        return [shared]
        #endif
    }

    /// Reads the vault item itself (one prompt after an update, at most).
    private static func readVault() -> VaultState {
        #if DEBUG
        if let reads = vaultReadsForTesting {
            reads.count += 1
            if reads.refusals > 0 { reads.refusals -= 1; return .unreadable(errSecUserCanceled) }
        }
        #endif
        var request = query(vaultAccount)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .unreadable(status)
        }
        return .loaded(values)
    }

    /// The vault, read once per launch. nil when it exists but can't be read (the user said no): then
    /// nothing is written either, so a refused prompt can never wipe saved keys. After a refusal it isn't
    /// read again (no prompt on every key), unless `retryIfRefused`: the user is saving a key, so they're
    /// there to answer one more prompt.
    private static func vault(retryIfRefused: Bool = false) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        let state = self.state
        if let cache = state.cache { return cache }
        if state.refused, !retryIfRefused { return nil }
        let wasRefused = state.refused
        switch readVault() {
        case .loaded(let values): state.cache = values
        case .missing: state.cache = [:]
        case .unreadable(let status):
            // A previous test build's vault: start a fresh one. (Not a cancelled prompt, which is how
            // tests simulate a refusal.)
            if isTesting, status != errSecUserCanceled {
                SecItemDelete(query(vaultAccount) as CFDictionary)
                state.cache = [:]
            } else {
                Log.app.error("keychain · the saved keys couldn't be read (\(status, privacy: .public))")
                state.refused = true
                return nil
            }
        }
        state.refused = false
        if wasRefused {
            DispatchQueue.main.async { NotificationCenter.default.post(name: didOpenAfterRefusal, object: nil) }
        }
        return state.cache
    }

    private static func encode(_ values: [String: String]) -> String? {
        (try? JSONEncoder().encode(values)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Changes the saved keys: the vault item is written first, and only once that worked does any copy
    /// in memory change. false (nothing changed) when the vault isn't open or the write failed; a failed
    /// write puts the previous contents back, since `add` deletes before it adds.
    private static func update(_ change: (inout [String: String]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let old = state.cache else { return false }
        var values = old
        change(&values)
        if values == old { return true }
        guard let data = encode(values), add(data, for: vaultAccount) else {
            if let previous = encode(old) { add(previous, for: vaultAccount) }
            Log.app.error("keychain · the saved keys couldn't be written")
            return false
        }
        for other in allStates where other.cache != nil { change(&other.cache!) }
        return true
    }

    /// The vault couldn't be read this launch (the prompt was cancelled): a nil from `get` then means
    /// "unknown", not "no key".
    static var isRefused: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.refused && state.cache == nil
    }

    /// A saved key. Background reads never ask again after a refusal; `retryIfRefused` is for a read the
    /// user just asked for (choosing a model), which may ask once more.
    static func get(_ account: String, retryIfRefused: Bool = false) -> String? {
        let (value, moved): (String?, Bool) = {
            lock.lock(); defer { lock.unlock() }
            guard let values = vault(retryIfRefused: retryIfRefused) else { return (nil, false) }
            if let value = values[account] { return (value, false) }
            if state.missing.contains(account) { return (nil, false) }
            // Saved by an older version as its own item: move it in, once. The old item goes only once
            // the vault holds it.
            guard let legacy = readLegacy(account) else { state.missing.insert(account); return (nil, false) }
            guard update({ $0[account] = legacy }) else { return (legacy, false) }
            SecItemDelete(query(account) as CFDictionary)
            return (legacy, true)
        }()
        // Never under the lock: a UserDefaults change posts a notification that can wait on the main
        // thread, and the main thread reads keys while drawing (a deadlock, seen in the test run).
        if moved { UserDefaults.standard.removeObject(forKey: openKey(account)) }
        return value
    }

    /// Saves a key. false when it wasn't saved: the vault exists but macOS wouldn't open it (the prompt
    /// was cancelled, also on the one retry), or the write failed. Nothing is written then, so the keys
    /// already saved stay. `retryIfRefused`: the user is saving it, so after an earlier refusal this
    /// launch it asks once more. Background writes pass false and never prompt again.
    @discardableResult
    static func set(_ value: String, for account: String, retryIfRefused: Bool = true) -> Bool {
        guard !value.isEmpty else { return delete(account, retryIfRefused: retryIfRefused) }
        let saved: Bool = {
            lock.lock(); defer { lock.unlock() }
            guard vault(retryIfRefused: retryIfRefused) != nil, update({ $0[account] = value }) else { return false }
            state.missing.remove(account)
            SecItemDelete(query(account) as CFDictionary)
            return true
        }()
        return saved
    }

    /// Writes only when the value differs from `current` (Settings applies on every change). false when
    /// a needed write failed, as in `set`.
    @discardableResult
    static func set(_ value: String, for account: String, ifChangedFrom current: String?) -> Bool {
        value != (current ?? "") ? set(value, for: account) : true
    }

    /// Removes a key. false when the vault couldn't be opened (as in `set`): the key may still be saved.
    @discardableResult
    static func delete(_ account: String, retryIfRefused: Bool = true) -> Bool {
        removeAll([account], retryIfRefused: retryIfRefused)
    }

    /// Removes these keys in one write (one prompt at most after a refusal). false when they couldn't be
    /// removed: nothing is touched then, not even an older version's own items (never a wipe while the
    /// saved keys are closed).
    @discardableResult
    static func removeAll(_ accounts: [String], retryIfRefused: Bool = true) -> Bool {
        guard !accounts.isEmpty else { return true }
        lock.lock()
        let removed = vault(retryIfRefused: retryIfRefused) != nil
            && update { values in accounts.forEach { values[$0] = nil } }
        if removed { for account in accounts { SecItemDelete(query(account) as CFDictionary) } }
        lock.unlock()
        // Outside the lock, as in `get`.
        if removed { for account in accounts { UserDefaults.standard.removeObject(forKey: openKey(account)) } }
        return removed
    }

    /// Removes every key whose account starts with `prefix` (a package's, whatever settings it declared
    /// over time), in one write, as `removeAll`. An older version's own items that match go too, only
    /// once the vault write worked.
    @discardableResult
    static func removeAll(prefix: String, retryIfRefused: Bool = true) -> Bool {
        guard !prefix.isEmpty else { return false }
        lock.lock()
        var removed = false
        var accounts: [String] = []
        if let values = vault(retryIfRefused: retryIfRefused) {
            accounts = values.keys.filter { $0.hasPrefix(prefix) }
            removed = update { values in accounts.forEach { values[$0] = nil } }
            if removed {
                let legacy = legacyAccounts().filter { $0.hasPrefix(prefix) && $0 != vaultAccount }
                for account in legacy { SecItemDelete(query(account) as CFDictionary) }
                accounts += legacy
            }
        }
        lock.unlock()
        // Outside the lock, as in `get`.
        if removed { for account in Set(accounts) { UserDefaults.standard.removeObject(forKey: openKey(account)) } }
        return removed
    }

    /// The accounts of this service's items (names only: reading names doesn't ask).
    private static func legacyAccounts() -> [String] {
        _ = noPromptsUnderTests
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let list = result as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// A key an older version saved as its own item (this read may ask, once per key).
    private static func readLegacy(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Forget the in-memory copy (tests, and after another process changed the vault).
    static func resetCache() {
        lock.lock()
        for s in [shared, state] { s.cache = nil; s.refused = false; s.missing = [] }
        lock.unlock()
    }

    /// Saves the item with its access list open to any app. That alone doesn't stop the prompts (the
    /// partition list still ties the item to this build), but it keeps the access list from adding a
    /// second, per-app prompt. Delete and add rather than update: an update keeps the old access list.
    @discardableResult
    private static func add(_ value: String, for account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        if let access = openAccess(label: "Lasso saved keys") { item[kSecAttrAccess as String] = access }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            // Never lose the keys: save it the default way.
            item[kSecAttrAccess as String] = nil
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return true
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

    /// The 0.16 flag that an item had been moved to the open access list (cleared as items move in).
    private static func openKey(_ account: String) -> String { "keychain.open.\(account)" }

    /// Whether an item's decrypt permission is open to any application (for tests; the vault's).
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

    /// Read a value, migrating it once from a legacy `UserDefaults` key into the Keychain. A read, so it
    /// never prompts again after a refusal, and the old copy stays until the move actually saved.
    static func getMigrating(_ account: String, legacyDefaultsKey: String) -> String? {
        if let value = get(account) { return value }
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            if set(legacy, for: account, retryIfRefused: false) {
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            }
            return legacy
        }
        return nil
    }
}
