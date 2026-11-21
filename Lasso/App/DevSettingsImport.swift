import Foundation

/// Xcode builds have their own app ID (`com.cjcarito.Lasso.dev`, so they don't take the installed
/// Lasso's permissions), and with it their own settings. The first time one runs it copies the
/// installed Lasso's settings, once, so it starts set up the same. Saved keys are shared anyway
/// (`Keychain.service`), and chats and packages live in the same folder.
enum DevSettingsImport {
    static let releaseID = "com.cjcarito.Lasso"
    static let doneKey = "dev.importedReleaseSettings"

    /// Copies each setting the dev build doesn't have yet. Returns how many it copied.
    @discardableResult
    static func run(into defaults: UserDefaults = .standard,
                    bundleID: String? = Bundle.main.bundleIdentifier,
                    release: [String: Any]? = UserDefaults.standard.persistentDomain(forName: releaseID)) -> Int {
        guard bundleID == releaseID + ".dev", !defaults.bool(forKey: doneKey) else { return 0 }
        defaults.set(true, forKey: doneKey)
        var copied = 0
        for (key, value) in release ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
