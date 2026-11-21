import AppKit
import SwiftUI

/// Browse the catalog: updates first, then every package, searchable. Get downloads it, checks it
/// against the catalog and opens the same review as any other package; only Add there installs.
struct PackageBrowseSheet: View {
    let dismiss: () -> Void
    let added: (String) -> Void
    /// Open with this package in view (a `lasso://install?id=` link).
    var focus: String?

    @State private var query = ""
    @State private var fetching: String?
    @State private var problem: String?
    @State private var review: (data: Data, files: PackageFiles.Files)?
    private var catalog: PackageCatalog { .shared }
    private var store: PackageStore { .shared }

    var body: some View {
        if let review {
            AddPackageSheet(dismiss: dismiss, added: added, reviewing: nil,
                            preload: (review.data, .catalog), preloadFiles: review.files,
                            back: { self.review = nil })
        } else {
            list.padding(22).frame(width: 520, height: 600)
                .task { if catalog.state != .loading, catalog.isStale { await catalog.refresh() } }
        }
    }

    private var shown: [PackageCatalog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.entries.filter { q.isEmpty || "\($0.name) \($0.summary) \($0.author) \($0.category ?? "")".lowercased().contains(q) }
            .sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
    }

    /// The linked package first, then updates, then the rest.
    private func rank(_ entry: PackageCatalog.Entry) -> Int {
        if entry.id == focus { return 0 }
        return updates[entry.id] != nil ? 1 : 2
    }

    /// Installed version by id, for packages the catalog has newer.
    private var updates: [String: String] {
        Dictionary(uniqueKeysWithValues: catalog.updates(store.installed).map { ($0.entry.id, $0.installed.package.version) })
    }

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Browse Packages").font(.title3.bold())
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            switch catalog.state {
            case .idle, .loading where catalog.entries.isEmpty:
                ProgressView("Reading the catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why) where catalog.entries.isEmpty:
                VStack(spacing: 10) {
                    Text(why).font(SettingsFont.label).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await catalog.refresh() } }.disabled(PrivacyMode.localOnly)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let focus, !catalog.entries.contains(where: { $0.id == focus }) {
                            Text("The link asked for “\(focus)”, which isn't in the catalog.")
                                .font(SettingsFont.sub).foregroundStyle(.orange)
                        }
                        SettingsCard(title: "", footnote: "Every package is checked automatically, and its scripts are read by a maintainer before it's listed. You see what each one can reach before adding it.") {
                            ForEach(shown) { entry in row(entry, update: updates[entry.id]) }
                            if shown.isEmpty { SettingsRow(query.isEmpty ? "The catalog is empty." : "Nothing matches “\(query)”.") { EmptyView() } }
                        }
                    }
                }
            }
            if let problem { Text(problem).font(SettingsFont.sub).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if case .failed(let why) = catalog.state, !catalog.entries.isEmpty {
                    Text("Couldn't refresh: \(why)").font(SettingsFont.sub).foregroundStyle(.orange).lineLimit(1)
                    Button("Try Again") { Task { await catalog.refresh() } }.buttonStyle(.link).font(SettingsFont.sub)
                } else if catalog.state == .loading {
                    ProgressView().controlSize(.small)
                } else if let checked = catalog.checked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))").font(SettingsFont.sub).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(_ entry: PackageCatalog.Entry, update from: String?) -> some View {
        let installed = store.installed.first { $0.id == entry.id }
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                SettingsTile(symbol: entry.symbol ?? "shippingbox", color: Color(nsColor: .systemGray))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(SettingsFont.label)
                    Text(from.map { "\($0) → \(entry.version)" } ?? entry.summary).font(SettingsFont.sub).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.tags.isEmpty {
                        Text(entry.tags.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if fetching == entry.id {
                    ProgressView().controlSize(.small)
                } else if catalog.isTooNew(entry) {
                    Text("Needs a newer Lasso").font(SettingsFont.sub).foregroundStyle(.secondary)
                } else if from != nil {
                    Button("Update…") { get(entry) }.buttonStyle(.bordered)
                } else if installed != nil {
                    Button("Open") { added(entry.id) }.buttonStyle(.bordered)
                } else {
                    Button("Get…") { get(entry) }.buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
            .background(entry.id == focus ? Color.accentColor.opacity(0.12) : .clear)
            Divider()
        }
    }

    private func get(_ entry: PackageCatalog.Entry) {
        fetching = entry.id
        problem = nil
        Task {
            defer { fetching = nil }
            do {
                let package = try await catalog.download(entry)
                review = (package.manifest, package.files)
            } catch {
                problem = "\(entry.name): \(error.localizedDescription)"
            }
        }
    }
}

/// Developer mode: make a package from a starter, load a folder of your own, and see its problems.
struct PackageDeveloperCard: View {
    @Binding var on: Bool
    let openPackage: (String) -> Void
    @State private var problem: String?
    private var store: PackageStore { .shared }

    var body: some View {
        SettingsCard(title: "", footnote: on ? (problem ?? "A loaded folder reloads by itself when you save a file.") : nil) {
            SettingsRow("Developer mode", symbol: "hammer", caption: "Make packages and run them from your own folder.") {
                SettingsSwitch(title: "", isOn: $on)
            }
            if on {
            SettingsRow("Make a package", caption: "Starts a folder from a template that already works.") {
                Menu("New Package…") {
                    ForEach(PackageStarters.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) { new(kind) }
                    }
                }
                .fixedSize()
            }
            SettingsRow("Load a folder", caption: "Runs a package straight from your folder while you work on it.") {
                Button("Load Folder…") { load() }.buttonStyle(.bordered)
            }
            }
        }
    }

    private func new(_ kind: PackageStarters.Kind) {
        let panel = NSSavePanel()
        panel.message = "Name the package's folder. The name becomes its id: lowercase letters, digits and “-”."
        panel.nameFieldStringValue = "my-package"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = url.lastPathComponent.lowercased()
        guard PackageValidator.matches(id, PackageValidator.idPattern) else {
            problem = "“\(url.lastPathComponent)” can't be an id: use 3 to 40 lowercase letters, digits and “-”, starting with a letter."
            return
        }
        do {
            let folder = url.deletingLastPathComponent().appending(path: id, directoryHint: .isDirectory)
            try PackageStarters.write(kind, id: id, to: folder)
            let package = try store.loadDeveloper(folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "lasso.json")])
            problem = nil
            openPackage(package.id)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a package folder (with a lasso.json inside)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let package = try store.loadDeveloper(folder)
            problem = nil
            openPackage(package.id)
        } catch let error as PackageStore.InstallError {
            if case .invalid(let list) = error { problem = list.map(\.description).joined(separator: "\n") }
            else { problem = error.localizedDescription }
        } catch {
            problem = "There's no readable lasso.json in that folder."
        }
    }
}

/// `lasso://install?id=<id>`: opens Browse at that package. It never installs: the user still clicks
/// Get, reads the review and clicks Add (spec, "Only a person installs").
@MainActor
enum PackageLinks {
    /// The package a link asked to show, until Browse opens it.
    static var requested: String? {
        get { PackageCatalog.shared.requested }
        set { PackageCatalog.shared.requested = newValue }
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "lasso", url.host?.lowercased() == "install",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              PackageValidator.matches(id, PackageValidator.idPattern) else { return false }
        requested = id
        SettingsWindow.openPane(.packages)
        Log.app.notice("packages · link asked to show \(id, privacy: .public) in Browse")
        return true
    }
}
