import Foundation

/// Packages built into Lasso: Tavily and SerpApi, which were hardcoded connectors before packages.
/// Offered under **+** until the catalog exists, and installed once for people who had a key saved.
enum BundledPackages {
    static let ids = ["tavily", "serpapi"]

    static func data(_ id: String, bundle: Bundle = .main) -> Data? {
        bundle.url(forResource: "\(id).lasso", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    static func all(bundle: Bundle = .main) -> [(data: Data, package: LassoPackage)] {
        ids.compactMap { id in
            guard let data = data(id, bundle: bundle), let package = PackageValidator.validate(data).package else { return nil }
            return (data, package)
        }
    }
}

/// From the hardcoded Tavily and SerpApi connectors to their packages, once (spec, "Tavily and
/// SerpApi"). A saved key moves to the package's Keychain item and the package is installed with the
/// connector's on/off state; no key, nothing installed. Usage counts carry over because the packages'
/// ids are the old counters' names.
@MainActor
enum PackageMigration {
    static let doneKey = "packages.migrated.connectors"

    struct Old { let packageID: String; let keyAccount: String; let enabledKey: String }
    static let connectors = [
        Old(packageID: "tavily", keyAccount: "tavily.apiKey", enabledKey: "connector.tavily.enabled"),
        Old(packageID: "serpapi", keyAccount: "serpapi.apiKey", enabledKey: "connector.serpapi.enabled"),
    ]

    static func run(store: PackageStore = .shared, defaults: UserDefaults = .standard, bundle: Bundle = .main,
                    readKey: (String) -> String? = { Keychain.getMigrating($0, legacyDefaultsKey: $0) },
                    deleteKey: (String) -> Void = { Keychain.delete($0, retryIfRefused: false); UserDefaults.standard.removeObject(forKey: $0) }) {
        guard !defaults.bool(forKey: doneKey) else { return }
        // At launch, in the background: never a prompt. A key the Keychain wouldn't take keeps its old
        // copy, and the migration runs again next launch.
        var finished = true
        for old in connectors {
            guard let key = readKey(old.keyAccount), !key.isEmpty else {
                // While the saved keys are closed, no key means unknown, not none: try again next launch.
                if Keychain.isRefused { finished = false }
                continue
            }
            let package: LassoPackage
            let wasOn = defaults.object(forKey: old.enabledKey) as? Bool ?? false
            let installedKey = installedByMigrationKey(old.packageID)
            if defaults.bool(forKey: installedKey), !store.isInstalled(old.packageID) {
                // An earlier run installed it and the user removed it since: never again. The old key
                // went with the package.
                deleteKey(old.keyAccount)
                defaults.removeObject(forKey: old.enabledKey)
                continue
            }
            if let installed = store.installed.first(where: { $0.id == old.packageID }) {
                // Installed by an earlier run whose key didn't save: fill in the key, if it's still empty.
                guard installed.origin == .bundled, let setting = installed.package.setting("key"),
                      store.value(installed.id, setting).isEmpty else { continue }
                package = installed.package
            } else {
                guard let data = BundledPackages.data(old.packageID, bundle: bundle) else { continue }
                do {
                    package = try store.install(data, origin: .bundled, enabled: wasOn)
                    defaults.set(true, forKey: installedKey)
                } catch {
                    Log.app.error("packages · couldn't move \(old.packageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            if let setting = package.setting("key"), !store.setValue(key, package.id, setting, retryIfRefused: false) {
                Log.app.error("packages · the \(old.packageID, privacy: .public) key wasn't saved; kept the old one, trying next launch")
                finished = false
                continue
            }
            deleteKey(old.keyAccount)
            defaults.removeObject(forKey: old.enabledKey)
            Log.app.notice("packages · moved the \(old.packageID, privacy: .public) connector to its package (on: \(wasOn, privacy: .public))")
        }
        if finished { defaults.set(true, forKey: doneKey) }
    }

    /// Set once a run installed this connector's package, so a later run (one whose key didn't save)
    /// never installs it again after the user removed it.
    static func installedByMigrationKey(_ packageID: String) -> String { "\(doneKey).\(packageID).installed" }
}
