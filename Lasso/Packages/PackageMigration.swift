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
                    deleteKey: (String) -> Void = { Keychain.delete($0); UserDefaults.standard.removeObject(forKey: $0) }) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for old in connectors {
            guard let key = readKey(old.keyAccount), !key.isEmpty,
                  !store.isInstalled(old.packageID),
                  let data = BundledPackages.data(old.packageID, bundle: bundle) else { continue }
            let wasOn = defaults.object(forKey: old.enabledKey) as? Bool ?? false
            do {
                let package = try store.install(data, origin: .bundled, enabled: wasOn)
                if let setting = package.setting("key") { store.setValue(key, package.id, setting) }
                deleteKey(old.keyAccount)
                defaults.removeObject(forKey: old.enabledKey)
                Log.app.notice("packages · moved the \(old.packageID, privacy: .public) connector to its package (on: \(wasOn, privacy: .public))")
            } catch {
                Log.app.error("packages · couldn't move \(old.packageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
