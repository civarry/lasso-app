import CryptoKit
import Foundation
import Observation

/// The installed packages: on disk in `~/Library/Application Support/Lasso/Packages/<id>/lasso.json`,
/// their on/off state and plain settings in preferences, secrets in the Keychain
/// (`package.<id>.<setting>`). Only the user's own clicks install, update or remove (spec, "Only a
/// person installs"); a manifest changed on disk by anything else is turned off until reviewed again.
@MainActor
@Observable
final class PackageStore {
    /// Settable so snapshot tests can show a throwaway store instead of this Mac's packages.
    static var shared = PackageStore()

    struct Installed: Identifiable, Equatable {
        var package: LassoPackage
        var enabled: Bool
        /// Where it came from, for the review and the package page.
        var origin: Origin
        /// The manifest changed on disk since Lasso installed it: off until reviewed.
        var changedOnDisk: Bool
        /// What the user approved, when it changed on disk (for the review's comparison).
        var approved: LassoPackage?
        var id: String { package.id }
    }

    enum Origin: String, Codable, Sendable { case file, pasted, bundled, catalog }

    /// One problem package found at launch (it stays listed so the user can remove it).
    struct Broken: Identifiable, Equatable {
        var id: String
        var problems: [PackageProblem]
    }

    private(set) var installed: [Installed] = []
    private(set) var broken: [Broken] = []

    let root: URL
    private let defaults: UserDefaults

    init(root: URL = PackageStore.defaultRoot, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        reload()
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lasso/Packages", directoryHint: .isDirectory)
    }

    // MARK: Records

    /// Kept in preferences, not in the package folder: anything that can edit a package's files could
    /// edit a copy kept beside them, and the review of a change would then compare against a lie.
    private struct Record: Codable {
        var sha256: String
        var enabled: Bool
        var origin: Origin
        /// The manifest the user approved, so a change on disk can be reviewed against it.
        var approved: Data?
    }

    private var recordsKey: String { "packages.records" }

    private var records: [String: Record] {
        get {
            guard let data = defaults.data(forKey: recordsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifestURL(_ id: String) -> URL { root.appending(path: "\(id)/lasso.json") }

    /// Reads every installed package again (at launch, and after any change).
    func reload() {
        var found: [Installed] = [], problems: [Broken] = []
        let records = self.records
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = folder.lastPathComponent
            guard let record = records[id], let data = try? Data(contentsOf: manifestURL(id)) else { continue }
            switch PackageValidator.validate(data) {
            case .valid(let package) where package.id == id:
                let changed = Self.sha256(data) != record.sha256
                let approved = changed ? record.approved.flatMap { PackageValidator.validate($0).package } : nil
                found.append(Installed(package: package, enabled: record.enabled && !changed,
                                       origin: record.origin, changedOnDisk: changed, approved: approved))
            case .valid:
                problems.append(Broken(id: id, problems: [PackageProblem(path: "id", message: "Doesn't match its folder.")]))
            case .invalid(let list):
                problems.append(Broken(id: id, problems: list))
            }
        }
        installed = found
        broken = problems
        PackageRegistry.shared.update(found.filter(\.enabled).map(\.package), settings: settingValues(for:))
    }

    // MARK: Install, remove, on/off

    enum InstallError: LocalizedError, Equatable {
        case invalid([PackageProblem])
        case alreadyInstalled(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let p): p.map(\.description).joined(separator: "\n")
            case .alreadyInstalled(let version): "Already installed (version \(version))."
            }
        }
    }

    /// What installing `data` would do: the package, and whether it updates one already installed.
    func review(_ data: Data) -> Result<(package: LassoPackage, replacing: LassoPackage?), InstallError> {
        switch PackageValidator.validate(data) {
        case .invalid(let problems): return .failure(.invalid(problems))
        case .valid(let package):
            let current = installed.first { $0.id == package.id }?.package
            if let current, !current.version.isEmpty, !PackageValidator.isNewer(package.version, than: current.version) {
                // A manifest changed on disk can be re-approved at the same version.
                if !(installed.first { $0.id == package.id }?.changedOnDisk ?? false) {
                    return .failure(.alreadyInstalled(current.version))
                }
            }
            return .success((package, current))
        }
    }

    /// Installs (or updates) after the user approved the review. Settings carry over by id.
    @discardableResult
    func install(_ data: Data, origin: Origin, enabled: Bool = true) throws -> LassoPackage {
        let package: LassoPackage
        switch review(data) {
        case .failure(let error): throw error
        case .success(let reviewed): package = reviewed.package
        }
        let dir = root.appending(path: package.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: manifestURL(package.id), options: .atomic)
        var records = self.records
        records[package.id] = Record(sha256: Self.sha256(data), enabled: enabled, origin: origin, approved: data)
        self.records = records
        reload()
        Log.app.notice("packages · installed \(package.id, privacy: .public) \(package.version, privacy: .public) from \(origin.rawValue, privacy: .public)")
        return package
    }

    /// Deletes the package, its preferences and its Keychain items. Its usage counts stay, so removing
    /// and reinstalling can't spend a free tier twice; files it saved to the workspace are the user's.
    func remove(_ id: String) {
        let package = installed.first { $0.id == id }?.package
        for setting in package?.settings ?? [] {
            if setting.kind == .secret { Keychain.delete(secretAccount(id, setting.id)) }
            else { defaults.removeObject(forKey: settingKey(id, setting.id)) }
        }
        try? FileManager.default.removeItem(at: root.appending(path: id, directoryHint: .isDirectory))
        var records = self.records
        records[id] = nil
        self.records = records
        reload()
        Log.app.notice("packages · removed \(id, privacy: .public)")
    }

    /// The on/off switch. It never approves a manifest changed on disk: that takes the review
    /// (`approveChange`), or the switch would turn on a package that quietly gained a host.
    func setEnabled(_ id: String, _ on: Bool) {
        var records = self.records
        guard var record = records[id] else { return }
        if on, installed.first(where: { $0.id == id })?.changedOnDisk == true { return }
        record.enabled = on
        records[id] = record
        self.records = records
        reload()
    }

    /// The user reviewed a manifest that changed on disk and chose Turn On.
    func approveChange(_ id: String) {
        var records = self.records
        guard var record = records[id], let data = try? Data(contentsOf: manifestURL(id)),
              PackageValidator.validate(data).package != nil else { return }
        record.sha256 = Self.sha256(data)
        record.approved = data
        record.enabled = true
        records[id] = record
        self.records = records
        reload()
    }

    /// The manifest as it is on disk now (for "Show the package file").
    func manifestData(_ id: String) -> Data? { try? Data(contentsOf: manifestURL(id)) }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    // MARK: Settings

    private func settingKey(_ id: String, _ setting: String) -> String { "package.\(id).setting.\(setting)" }
    nonisolated func secretAccount(_ id: String, _ setting: String) -> String { "package.\(id).\(setting)" }

    func value(_ id: String, _ setting: PackageSetting) -> String {
        if setting.kind == .secret { return Keychain.get(secretAccount(id, setting.id)) ?? "" }
        return defaults.string(forKey: settingKey(id, setting.id)) ?? setting.defaultValue ?? ""
    }

    func setValue(_ value: String, _ id: String, _ setting: PackageSetting) {
        if setting.kind == .secret {
            let account = secretAccount(id, setting.id)
            if value.isEmpty { Keychain.delete(account) } else { Keychain.set(value, for: account) }
        } else {
            defaults.set(value, forKey: settingKey(id, setting.id))
        }
        reload()
    }

    /// `settings.<id>` values for templates, and the secrets among them (for redaction).
    func settingValues(for package: LassoPackage) -> (values: [String: String], secrets: [String]) {
        var values: [String: String] = [:], secrets: [String] = []
        for setting in package.settings {
            let v = value(package.id, setting)
            values["settings.\(setting.id)"] = v
            if setting.kind == .secret, !v.isEmpty { secrets.append(v) }
        }
        return (values, secrets)
    }

    /// Settings a package's commands use that have no value yet (a key not entered).
    func missingSettings(_ package: LassoPackage) -> [PackageSetting] {
        package.settings.filter { $0.kind != .toggle && $0.kind != .choice && value(package.id, $0).isEmpty }
    }
}

/// What search reads while a turn runs, off the main actor: the enabled packages with their settings
/// at the moment they last changed.
final class PackageRegistry: @unchecked Sendable {
    static let shared = PackageRegistry()

    struct Entry: Sendable {
        var package: LassoPackage
        var values: [String: String]
        var secrets: [String]
        /// Every setting it needs has a value.
        var ready: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var all: [Entry] { lock.withLock { entries } }

    @MainActor
    func update(_ packages: [LassoPackage], settings: (LassoPackage) -> (values: [String: String], secrets: [String])) {
        let built = packages.map { package -> Entry in
            let s = settings(package)
            let ready = package.settings.allSatisfy { setting in
                setting.kind == .toggle || setting.kind == .choice || !(s.values["settings.\(setting.id)"] ?? "").isEmpty
            }
            return Entry(package: package, values: s.values, secrets: s.secrets, ready: ready)
        }
        lock.withLock { entries = built }
    }

    /// Search commands that can run now: enabled, set up, and not paused by local-only mode.
    func searchCommands(localOnly: Bool = PrivacyMode.localOnly) -> [(entry: Entry, command: PackageCommand)] {
        all.filter(\.ready).flatMap { entry in
            entry.package.commands.filter { $0.surfaces.contains(.search) }.compactMap { command in
                let reachesOffMac = !PackageHTTP.allowedHosts(entry.package, values: entry.values)
                    .allSatisfy(PackageValidator.isLoopback)
                return localOnly && reachesOffMac ? nil : (entry, command)
            }
        }
    }

    var hasActiveSearch: Bool { !searchCommands().isEmpty }
}
