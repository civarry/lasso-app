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

    enum Origin: String, Codable, Sendable { case file, pasted, bundled, catalog, developer }

    /// One problem package found at launch (it stays listed so the user can remove it).
    struct Broken: Identifiable, Equatable {
        var id: String
        var problems: [PackageProblem]
    }

    private(set) var installed: [Installed] = []
    private(set) var broken: [Broken] = []
    /// Every enabled package's patches, applied in the patch order.
    private(set) var patches = AppliedPatches()

    let root: URL
    private let defaults: UserDefaults

    /// Where scripts keep their data (`…/PackageData/<id>/`), beside the packages folder.
    var dataRoot: URL { root.deletingLastPathComponent().appending(path: root.lastPathComponent == "Packages" ? "PackageData" : root.lastPathComponent + "-data", directoryHint: .isDirectory) }

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
        /// Commands the user switched off (the package's other commands keep working).
        var disabledCommands: [String]?
        /// Commands the user stopped offering to models as tools (they keep their other surfaces).
        var offTools: [String]?
        /// SHA-256 of each file beside the manifest (scripts), as approved.
        var files: [String: String]?
        /// The user let this package's scripts run without the sandbox. Never set by a package.
        var fullAccess: Bool?
        /// Developer mode: the folder it was loaded from, reloaded when it changes.
        var source: String?
    }

    private var recordsKey: String { "packages.records" }

    private var records: [String: Record] {
        get {
            guard let data = defaults.data(forKey: recordsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }

    nonisolated static func sha256(_ data: Data) -> String { PackageFiles.sha256(data) }

    private func manifestURL(_ id: String) -> URL { root.appending(path: "\(id)/lasso.json") }

    /// A package's folder on disk.
    func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// Files beside a manifest (`scripts/…`, a README), by path inside the package.
    typealias Files = PackageFiles.Files

    /// Everything in a package folder but `lasso.json` (`PackageFiles.read`).
    nonisolated static func readFiles(in folder: URL) throws -> Files {
        do { return try PackageFiles.read(folder) } catch let e as PackageFiles.Invalid { throw InstallError.invalid(e.problems) }
    }
    nonisolated static func hashes(_ files: Files) -> [String: String] { PackageFiles.hashes(files) }
    nonisolated static func contentHash(_ manifest: Data, _ files: Files) -> String { PackageFiles.contentHash(manifest, files) }
    nonisolated static func fileProblems(_ package: LassoPackage, _ files: Files) -> [PackageProblem] { PackageFiles.problems(package, files) }

    /// Where a package's scripts run: its folder, data folder, workspace folder and picked folders.
    func places(for package: LassoPackage) -> PackageScript.Places {
        let folders = package.settings.filter { $0.kind == .folder }.compactMap { setting -> URL? in
            let path = value(package.id, setting)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        return PackageScript.Places(package: folder(package.id), data: dataRoot.appending(path: package.id, directoryHint: .isDirectory),
                                    workspace: PackageScript.workspace(package.id), folders: folders)
    }

    // MARK: Developer mode

    /// Problems in a developer package's folder since it last loaded cleanly (it keeps the last good copy).
    private(set) var developerProblems: [String: [PackageProblem]] = [:]
    private var watch: Task<Void, Never>?

    /// The folder a developer package was loaded from.
    func developerSource(_ id: String) -> URL? { records[id]?.source.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// Loads (or reloads) a package from a folder of the user's own, without asking for a newer version.
    @discardableResult
    func loadDeveloper(_ folder: URL) throws -> LassoPackage {
        let data = try Data(contentsOf: folder.appending(path: "lasso.json"))
        let package = try install(data, files: try Self.readFiles(in: folder), origin: .developer, source: folder)
        developerProblems[package.id] = nil
        watchDeveloperFolders()
        return package
    }

    /// Every 2 seconds while there are developer packages: a folder that changed is loaded again, or
    /// its problems are kept to show on the package's page.
    func watchDeveloperFolders() {
        guard watch == nil, records.values.contains(where: { $0.source != nil }) else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if !self.reloadChangedDeveloperFolders() { self.watch = nil; return }
            }
        }
    }

    /// Returns false once there's nothing left to watch.
    @discardableResult
    func reloadChangedDeveloperFolders() -> Bool {
        let developers = records.filter { $0.value.source != nil }
        for (id, record) in developers {
            guard let path = record.source else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appending(path: "lasso.json")),
                  let files = try? Self.readFiles(in: folder) else {
                developerProblems[id] = [PackageProblem(path: "", message: "Its folder can't be read: \(path)")]
                continue
            }
            guard Self.contentHash(data, files) != record.sha256 else { continue }
            switch review(data, files: files, anyVersion: true) {
            case .success(let reviewed) where reviewed.package.id == id:
                _ = try? install(data, files: files, origin: .developer, enabled: record.enabled, source: folder)
                developerProblems[id] = nil
                Log.app.notice("packages · reloaded developer package \(id, privacy: .public)")
            case .success:
                developerProblems[id] = [PackageProblem(path: "id", message: "Its id changed. Load the folder again.")]
            case .failure(let error):
                if case .invalid(let list) = error { developerProblems[id] = list }
            }
        }
        return !developers.isEmpty
    }

    /// Whether the user gave this package's scripts full access.
    func hasFullAccess(_ id: String) -> Bool { records[id]?.fullAccess == true }

    /// The user's switch for full access (Settings, after a warning).
    func setFullAccess(_ id: String, _ on: Bool) {
        var records = self.records
        guard var record = records[id] else { return }
        record.fullAccess = on
        records[id] = record
        self.records = records
        reload()
    }

    /// Which files differ from what's installed (for the review of an update).
    func changedFiles(_ id: String, _ files: Files) -> [String] {
        let old = records[id]?.files ?? [:], new = Self.hashes(files)
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    /// Reads every installed package again (at launch, and after any change).
    func reload() {
        var found: [Installed] = [], problems: [Broken] = []
        let records = self.records
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = folder.lastPathComponent
            guard let record = records[id], let data = try? Data(contentsOf: manifestURL(id)) else { continue }
            let files = (try? Self.readFiles(in: folder)) ?? ["": Data()]
            switch PackageValidator.validate(data) {
            case .valid(let package) where package.id == id:
                let changed = Self.contentHash(data, files) != record.sha256
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
        let active = found.filter(\.enabled).map { item -> LassoPackage in
            var package = item.package
            let off = Set(records[item.id]?.disabledCommands ?? [])
            package.commands.removeAll { off.contains($0.id) }
            return package
        }
        PackageRegistry.shared.update(active, settings: settingValues(for:),
                                      offTools: { Set(records[$0]?.offTools ?? []) },
                                      places: { self.places(for: $0) },
                                      fullAccess: { records[$0]?.fullAccess == true })
        patches = AppliedPatches.apply(inPatchOrder(active))
        PatchState.shared.update(patches)
        NotificationCenter.default.post(name: PackageStore.didChange, object: nil)
    }

    // MARK: Patch order

    /// Package ids in the order their patches apply: newest install last, unless the user picks one.
    private var patchOrder: [String] {
        get { defaults.stringArray(forKey: "packages.patchOrder") ?? [] }
        set { defaults.set(newValue, forKey: "packages.patchOrder") }
    }

    /// `packages` sorted by the patch order; any not in it (installed before it existed) come first.
    func inPatchOrder(_ packages: [LassoPackage]) -> [LassoPackage] {
        let order = patchOrder
        return packages.enumerated().sorted { a, b in
            switch (order.firstIndex(of: a.element.id), order.firstIndex(of: b.element.id)) {
            case let (x?, y?): x < y
            case (nil, _?): true
            case (_?, nil): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The user chose this package's changes where packages disagree: its patches apply last.
    func preferPatches(of id: String) {
        patchOrder = patchOrder.filter { $0 != id } + [id]
        reload()
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
    func review(_ data: Data, files: Files = [:], anyVersion: Bool = false) -> Result<(package: LassoPackage, replacing: LassoPackage?), InstallError> {
        switch PackageValidator.validate(data) {
        case .invalid(let problems): return .failure(.invalid(problems))
        case .valid(let package):
            let missing = Self.fileProblems(package, files)
            if !missing.isEmpty { return .failure(.invalid(missing)) }
            let current = installed.first { $0.id == package.id }?.package
            if !anyVersion, let current, !current.version.isEmpty, !PackageValidator.isNewer(package.version, than: current.version) {
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
    func install(_ data: Data, files: Files = [:], origin: Origin, enabled: Bool = true, source: URL? = nil,
                 allowOlder: Bool = false) throws -> LassoPackage {
        let package: LassoPackage
        switch review(data, files: files, anyVersion: origin == .developer || allowOlder) {
        case .failure(let error): throw error
        case .success(let reviewed): package = reviewed.package
        }
        let fm = FileManager.default
        let dir = folder(package.id)
        // The folder is replaced whole, so a file the update dropped doesn't linger.
        let staging = root.appending(path: ".\(package.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try data.write(to: staging.appending(path: "lasso.json"))
        for (path, contents) in files {
            let url = staging.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            if path.hasPrefix("scripts/") { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        if fm.fileExists(atPath: dir.path) {
            // The version it replaces is kept (one step), for Go back: packages now carry fixes that
            // used to ship in Lasso releases. Not for developer folders or a copy changed on disk.
            let current = installed.first { $0.id == package.id }
            if origin != .developer, let current, !current.changedOnDisk, current.package.version != package.version {
                let kept = previousFolder(package.id)
                try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: kept)
                try fm.moveItem(at: dir, to: kept)
            } else {
                try fm.removeItem(at: dir)
            }
        }
        try fm.moveItem(at: staging, to: dir)
        var records = self.records
        let old = records[package.id]
        // A fresh install starts empty: a key an earlier uninstall couldn't remove (the saved keys were
        // closed) doesn't come back with it. Only when they open without asking; never a wipe otherwise.
        if old == nil {
            let secrets = package.settings.filter { $0.kind == .secret }.map { secretAccount(package.id, $0.id) }
            Keychain.removeAll(secrets, retryIfRefused: false)
        }
        // Full access survives an update only when no script changed.
        let keepsFullAccess = old?.fullAccess == true && (old?.files ?? [:]) == Self.hashes(files)
        // So does running by itself, and only if its event commands are the same ones.
        if let previous = installed.first(where: { $0.id == package.id })?.package {
            let events = { (p: LassoPackage) in p.commands.filter { $0.surfaces.contains(.event) } }
            if events(previous) != events(package) || (old?.files ?? [:]) != Self.hashes(files) {
                PackageEvents.setAllowed(false, package.id, defaults)
            }
        }
        records[package.id] = Record(sha256: Self.contentHash(data, files), enabled: enabled, origin: origin, approved: data,
                                     disabledCommands: old?.disabledCommands, offTools: old?.offTools,
                                     files: Self.hashes(files), fullAccess: keepsFullAccess ? true : nil,
                                     source: origin == .developer ? (source?.path ?? old?.source) : nil)
        self.records = records
        if !patchOrder.contains(package.id) { patchOrder.append(package.id) }
        reload()
        Log.app.notice("packages · installed \(package.id, privacy: .public) \(package.version, privacy: .public) from \(origin.rawValue, privacy: .public)")
        return package
    }

    /// The version an update replaced, kept for Go back.
    private func previousFolder(_ id: String) -> URL {
        root.appending(path: ".previous/\(id)", directoryHint: .isDirectory)
    }

    /// The version Go back would return to, if one is kept.
    func previousVersion(_ id: String) -> String? {
        guard let data = try? Data(contentsOf: previousFolder(id).appending(path: "lasso.json")),
              let package = PackageValidator.validate(data).package, package.id == id else { return nil }
        return package.version
    }

    /// Go back: reinstalls the kept version (the user approved it when they installed it), keeping the
    /// package's settings and its on/off state. One step: the newer version isn't kept.
    func goBack(_ id: String) throws {
        let kept = previousFolder(id)
        let data = try Data(contentsOf: kept.appending(path: "lasso.json"))
        let files = try Self.readFiles(in: kept)
        let record = records[id]
        try install(data, files: files, origin: record?.origin ?? .catalog, enabled: record?.enabled ?? true, allowOlder: true)
        try? FileManager.default.removeItem(at: kept)
        reload()
    }

    /// Deletes the package, its preferences and its Keychain items. Its usage counts stay, so removing
    /// and reinstalling can't spend a free tier twice; files it saved to the workspace are the user's.
    /// false when its keys couldn't be removed (the saved keys wouldn't open): they stay saved, and a
    /// fresh install of this id clears them (`install`).
    @discardableResult
    func remove(_ id: String) -> Bool {
        // Every version it had, not just the one on disk now: a broken package has none readable, and a
        // setting an update dropped is still stored. A later package with this id must start empty.
        var versions: [LassoPackage] = []
        if let current = installed.first(where: { $0.id == id })?.package { versions.append(current) }
        if let approved = records[id]?.approved, let package = PackageValidator.validate(approved).package { versions.append(package) }
        if let disk = manifestData(id), let package = PackageValidator.validate(disk).package { versions.append(package) }
        if let previous = try? Data(contentsOf: previousFolder(id).appending(path: "lasso.json")),
           let package = PackageValidator.validate(previous).package { versions.append(package) }
        var secrets: Set<String> = []
        for package in versions {
            PackageHotkeys.clear(package)
            for setting in package.settings where setting.kind == .secret { secrets.insert(secretAccount(id, setting.id)) }
        }
        // One write for all of them: one prompt at most, not one per version.
        let keysRemoved = Keychain.removeAll(secrets.sorted())
        if !keysRemoved { Log.app.error("packages · \(id, privacy: .public)'s keys couldn't be removed: the saved keys are closed") }
        unreadSecrets.subtract(secrets)
        let prefix = "package.\(id).setting."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: root.appending(path: id, directoryHint: .isDirectory))
        try? FileManager.default.removeItem(at: previousFolder(id))
        // Its data folder goes too; what it saved to ~/LassoWorkspace/<id>/ is the user's.
        try? FileManager.default.removeItem(at: dataRoot.appending(path: id, directoryHint: .isDirectory))
        var records = self.records
        records[id] = nil
        self.records = records
        patchOrder.removeAll { $0 == id }
        SourcePreferences.forget(id)
        PackageEvents.setAllowed(false, id, defaults)
        reload()
        Log.app.notice("packages · removed \(id, privacy: .public)")
        return keysRemoved
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
    /// `reviewed`: the manifest the review showed. If the disk changed again since, nothing is approved
    /// (the next review shows the new one): the user approves what they read, not what's there at the click.
    @discardableResult
    func approveChange(_ id: String, reviewed: Data? = nil) -> Bool {
        var records = self.records
        guard var record = records[id], let data = try? Data(contentsOf: manifestURL(id)),
              PackageValidator.validate(data).package != nil else { return false }
        if let reviewed, reviewed != data { reload(); return false }
        let files = (try? Self.readFiles(in: folder(id))) ?? [:]
        guard let package = PackageValidator.validate(data).package, Self.fileProblems(package, files).isEmpty else { return false }
        if record.files ?? [:] != Self.hashes(files) { record.fullAccess = nil }
        record.sha256 = Self.contentHash(data, files)
        record.files = Self.hashes(files)
        record.approved = data
        record.enabled = true
        records[id] = record
        self.records = records
        reload()
        return true
    }

    /// The manifest as it is on disk now (for "Show the package file").
    func manifestData(_ id: String) -> Data? { try? Data(contentsOf: manifestURL(id)) }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    /// Posted after packages change (hotkeys re-register, menus rebuild).
    static let didChange = Notification.Name("lasso.packages.didChange")

    func isCommandEnabled(_ id: String, _ command: String) -> Bool {
        !(records[id]?.disabledCommands ?? []).contains(command)
    }

    func setCommandEnabled(_ id: String, _ command: String, _ on: Bool) {
        var records = self.records
        guard var record = records[id] else { return }
        var off = Set(record.disabledCommands ?? [])
        if on { off.remove(command) } else { off.insert(command) }
        record.disabledCommands = off.sorted()
        records[id] = record
        self.records = records
        reload()
    }

    func isToolOffered(_ id: String, _ command: String) -> Bool {
        !(records[id]?.offTools ?? []).contains(command)
    }

    /// Whether models are offered this command as a tool (Settings › Packages › Tools).
    func setToolOffered(_ id: String, _ command: String, _ on: Bool) {
        var records = self.records
        guard var record = records[id] else { return }
        var off = Set(record.offTools ?? [])
        if on { off.remove(command) } else { off.insert(command) }
        record.offTools = off.sorted()
        records[id] = record
        self.records = records
        reload()
    }

    // MARK: Settings

    private func settingKey(_ id: String, _ setting: String) -> String { "package.\(id).setting.\(setting)" }
    nonisolated func secretAccount(_ id: String, _ setting: String) -> String { "package.\(id).\(setting)" }

    func value(_ id: String, _ setting: PackageSetting) -> String {
        if setting.kind == .secret {
            let account = secretAccount(id, setting.id)
            if let value = Keychain.get(account) { return value }
            if Keychain.isRefused { observeVaultOpening(); unreadSecrets.insert(account) }
            return ""
        }
        return defaults.string(forKey: settingKey(id, setting.id)) ?? setting.defaultValue ?? ""
    }

    /// Secrets handed out as "" because the saved keys couldn't be opened: "" from them is unknown, not
    /// cleared, so writing it back (a settings row that loaded then, leaving the page after the vault
    /// opened) mustn't delete the real key. Cleared once the vault has opened and the rows reloaded.
    private var unreadSecrets: Set<String> = []
    private var vaultObserver: NSObjectProtocol?

    private func observeVaultOpening() {
        guard vaultObserver == nil else { return }
        vaultObserver = NotificationCenter.default.addObserver(forName: Keychain.didOpenAfterRefusal, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unreadSecrets = [] }
        }
    }

    /// false when a secret wasn't saved (the Keychain's saved-keys prompt was cancelled). `retryIfRefused`
    /// as in `Keychain.set`: false for a write the user didn't just make (the launch's migration).
    @discardableResult
    func setValue(_ value: String, _ id: String, _ setting: PackageSetting, retryIfRefused: Bool = true) -> Bool {
        var saved = true
        if setting.kind == .secret {
            let account = secretAccount(id, setting.id)
            if value.isEmpty, unreadSecrets.contains(account) { return true }   // unknown, not cleared
            saved = Keychain.set(value, for: account, retryIfRefused: retryIfRefused)   // empty deletes
            if saved { unreadSecrets.remove(account) }
        } else {
            defaults.set(value, forKey: settingKey(id, setting.id))
        }
        reload()
        return saved
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
        /// Command ids the user doesn't offer to models as tools.
        var offTools: Set<String> = []
        /// Where its scripts run.
        var places: PackageScript.Places?
        /// The user let its scripts run without the sandbox.
        var fullAccess = false
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var all: [Entry] { lock.withLock { entries } }

    /// Puts back a list read earlier (tests that stand in their own packages).
    func restore(_ saved: [Entry]) { lock.withLock { entries = saved } }

    @MainActor
    func update(_ packages: [LassoPackage], settings: (LassoPackage) -> (values: [String: String], secrets: [String]),
                offTools: (String) -> Set<String> = { _ in [] },
                places: (LassoPackage) -> PackageScript.Places? = { _ in nil },
                fullAccess: (String) -> Bool = { _ in false }) {
        let built = packages.map { package -> Entry in
            let s = settings(package)
            let ready = package.settings.allSatisfy { setting in
                setting.kind == .toggle || setting.kind == .choice || !(s.values["settings.\(setting.id)"] ?? "").isEmpty
            }
            return Entry(package: package, values: s.values, secrets: s.secrets, ready: ready, offTools: offTools(package.id),
                         places: places(package), fullAccess: fullAccess(package.id))
        }
        lock.withLock { entries = built }
    }

    /// Web search packages that can run now (enabled, set up, not paused by local-only mode): what the
    /// globe's web search adds. Sources on this Mac aren't here: they run when a message mentions them
    /// or Lasso picks them (`PackageSource`), never as part of web search (docs/LOCAL-SOURCES.md).
    func searchCommands(localOnly: Bool = PrivacyMode.localOnly) -> [(entry: Entry, command: PackageCommand)] {
        all.filter { $0.ready && PackageRequirements.missingNow($0.package) == nil }.flatMap { entry in
            entry.package.commands.filter { $0.surfaces.contains(.search) && !PackageSource.isOnThisMac(entry, $0) }.compactMap { command in
                let reachesOffMac = !PackageHTTP.allowedHosts(entry.package, values: entry.values)
                    .allSatisfy(PackageValidator.isLoopback)
                return localOnly && reachesOffMac ? nil : (entry, command)
            }
        }
    }

    var hasActiveSearch: Bool { !searchCommands().isEmpty }
}
