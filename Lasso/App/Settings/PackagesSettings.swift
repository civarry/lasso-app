import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Packages (build step 1: search packages). Designed with a separate UI/UX review; the
/// decisions are recorded in `docs/APP_FLOW.md`. Packages apply at once through `PackageStore`.

/// Where a Settings stack can go: one of Lasso's own pages, or an installed package's page.
enum SettingsDestination: Hashable {
    case route(SettingsRoute)
    case package(String)
}

// MARK: - Status

/// What a package's row says, first case that applies (orange only when the user has something to do).
struct PackageStatus: Equatable {
    var text: String
    var needsAction: Bool
    /// No switch at all (broken, or changed on disk: only the review turns it back on).
    var hidesSwitch: Bool = false
    var switchDisabled: Bool = false

    @MainActor
    static func of(_ item: PackageStore.Installed, store: PackageStore = .shared, localOnly: Bool = PrivacyMode.localOnly,
                   usedToday: Int? = nil, usedMonth: Int? = nil, now: Date = Date()) -> PackageStatus {
        let package = item.package
        if item.changedOnDisk {
            return PackageStatus(text: "Changed outside Lasso. Review to turn on", needsAction: true, hidesSwitch: true)
        }
        if !item.enabled { return PackageStatus(text: "Off", needsAction: false) }
        let values = store.settingValues(for: package).values
        if localOnly, !PackageHTTP.allowedHosts(package, values: values).allSatisfy(PackageValidator.isLoopback) {
            return PackageStatus(text: "Paused in local-only mode", needsAction: false, switchDisabled: true)
        }
        if store.missingSettings(package).contains(where: { $0.kind == .secret }) {
            return PackageStatus(text: "Needs a key", needsAction: true)
        }
        if !store.missingSettings(package).isEmpty {
            return PackageStatus(text: "Needs setting up", needsAction: true)
        }
        let today = usedToday ?? SearchQuota.usedToday(package.id)
        let month = usedMonth ?? SearchQuota.usedMonth(package.id)
        if let daily = package.limits?.daily, today >= daily {
            return PackageStatus(text: "Daily limit reached. Back tomorrow", needsAction: false)
        }
        if let monthly = package.limits?.monthly, month >= monthly {
            return PackageStatus(text: "Monthly limit reached. Back on \(firstOfNextMonth(now))", needsAction: false)
        }
        let role = package.commands.contains { $0.run.role == .primary } ? "Every search" : "When results are thin"
        if let monthly = package.limits?.monthly { return PackageStatus(text: "\(role) · \(month) of \(monthly) this month", needsAction: false) }
        return PackageStatus(text: role, needsAction: false)
    }

    static func firstOfNextMonth(_ now: Date) -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return next.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The command's role, in words (review, page caption).
    static func roleLine(_ command: PackageCommand) -> String {
        command.run.role == .primary ? "Adds results to every web search" : "Adds results when web search comes back thin"
    }
}

// MARK: - Icon

/// A package's icon: its site's logo on a white rounded square, or its symbol on a grey tile. The same
/// corner radius as every other Settings tile.
struct PackageIcon: View {
    let package: LassoPackage?
    var size: CGFloat = 22

    var body: some View {
        let symbol = package?.iconSymbol ?? "shippingbox"
        Group {
            if let domain = package?.iconDomain, !PrivacyMode.localOnly,
               let url = URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.white)
                            .frame(width: size, height: size)
                            .overlay(image.resizable().aspectRatio(contentMode: .fit).padding(size * 0.14))
                    } else {
                        SettingsTile(symbol: symbol, color: Color(nsColor: .systemGray), size: size)
                    }
                }
            } else {
                SettingsTile(symbol: symbol, color: Color(nsColor: .systemGray), size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Hub

struct PackagesHub: View {
    @Binding var webSearchOn: Bool
    let localOnly: Bool
    let openPackage: (String) -> Void

    @State private var adding = false
    private var store: PackageStore { .shared }

    var body: some View {
        SettingsPage {
            SettingsHubHeader(pane: .packages)
            SettingsCard(title: "Search",
                         footnote: localOnly ? "Paused in local-only mode."
                             : "Packages marked Every search add results first. The rest fill in when results are thin.") {
                webSearchRow
                ForEach(store.broken) { broken in
                    PackageRow(icon: PackageIcon(package: nil), name: broken.id,
                               status: PackageStatus(text: "Can't be used: \(broken.problems.count) problem\(broken.problems.count == 1 ? "" : "s")",
                                                     needsAction: true, hidesSwitch: true),
                               isOn: .constant(false), open: { openPackage(broken.id) })
                }
                ForEach(store.installed.sorted { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }) { item in
                    PackageRow(icon: PackageIcon(package: item.package), name: item.package.name,
                               status: PackageStatus.of(item, localOnly: localOnly),
                               isOn: Binding(get: { item.enabled }, set: { store.setEnabled(item.id, $0) }),
                               open: { openPackage(item.id) })
                }
                if store.installed.isEmpty, store.broken.isEmpty { emptyRow }
                addStrip
            }
        }
        .sheet(isPresented: $adding) {
            AddPackageSheet(dismiss: { adding = false }, added: { id in adding = false; openPackage(id) })
        }
    }

    private var webSearchRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SettingsTile(symbol: "globe", color: Color(nsColor: .systemBlue))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web search").font(SettingsFont.label)
                    Text(localOnly ? "Paused in local-only mode" : "Built in. Wikipedia, DuckDuckGo, Reddit. No key")
                        .font(SettingsFont.sub).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SettingsSwitch(title: "", isOn: $webSearchOn).disabled(localOnly)
                Color.clear.frame(width: PackageRowMetrics.chevronWidth)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)
            Divider().padding(.leading, SettingsMetrics.rowPaddingH + 32)
        }
    }

    private var emptyRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("No search packages yet. Add Tavily, SerpApi or a package file for stronger, ranked results.")
                    .font(SettingsFont.sub).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Add Package…") { adding = true }.buttonStyle(.bordered)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 12)
            Divider()
        }
    }

    /// The + at the bottom of the list it adds to, like Login Items.
    private var addStrip: some View {
        HStack {
            Button { adding = true } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Add a package")
            .accessibilityLabel("Add a package")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

enum PackageRowMetrics {
    static let chevronWidth: CGFloat = 10
    static let switchWidth: CGFloat = 32
}

/// One package in the list: everything but the switch opens its page, so a click on the switch never
/// navigates. Rows without a switch keep its space, so the chevrons line up.
struct PackageRow<Icon: View>: View {

    let icon: Icon
    let name: String
    let status: PackageStatus
    @Binding var isOn: Bool
    let open: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        icon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(SettingsFont.label).foregroundStyle(.primary)
                            Text(status.text).font(SettingsFont.sub)
                                .foregroundStyle(status.needsAction ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if status.hidesSwitch {
                    Color.clear.frame(width: PackageRowMetrics.switchWidth, height: 1)
                } else {
                    SettingsSwitch(title: "", isOn: $isOn).disabled(status.switchDisabled)
                }
                Button(action: open) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .frame(width: PackageRowMetrics.chevronWidth)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)
            Divider().padding(.leading, SettingsMetrics.rowPaddingH + 32)
        }
    }
}

// MARK: - What a package can do (review and page share it, so they can't disagree)

struct PackagePermissionsList: View {
    let package: LassoPackage
    /// The version it replaces or was approved as: what's new is tagged.
    var compareTo: LassoPackage?
    var values: [String: String] = [:]

    var body: some View {
        SettingsCard(title: "What it does") {
            ForEach(package.commands, id: \.id) { command in
                line("magnifyingglass", PackageStatus.roleLine(command),
                     tag: tag(changed: compareTo.map { old in old.command(command.id)?.run.role != command.run.role } ?? false,
                              new: compareTo.map { $0.command(command.id) == nil } ?? false))
            }
            if let old = compareTo {
                ForEach(old.commands.filter { package.command($0.id) == nil }, id: \.id) { gone in
                    line("minus.circle", "No longer: \(gone.title)", tag: nil)
                }
            }
        }
        SettingsCard(title: "What it can reach") {
            ForEach(package.hosts, id: \.self) { host in
                line("network", "Sends your searches to \(host)",
                     tag: tag(changed: false, new: compareTo.map { !$0.hosts.contains(host) } ?? false))
            }
            ForEach(package.settings.filter { $0.kind == .server }, id: \.id) { setting in
                let host = URL(string: values["settings.\(setting.id)"] ?? "")?.host
                line("network", host.map { PackageValidator.isLoopback($0) ? "Sends your searches to a server on this Mac" : "Sends your searches to \($0)" }
                         ?? "Sends your searches to a server you choose",
                     tag: tag(changed: false, new: compareTo.map { $0.setting(setting.id) == nil } ?? false))
            }
            ForEach(package.settings.filter { $0.kind == .secret }, id: \.id) { setting in
                line("key.fill", "Needs \(article(setting.label)) \(setting.label). It's kept in your Keychain and sent only to \(hostList).",
                     tag: tag(changed: false, new: compareTo.map { $0.setting(setting.id) == nil } ?? false))
            }
            if let limits = package.limits {
                line("gauge.with.needle", limitsLine(limits), tag: tag(changed: compareTo.map { $0.limits != limits } ?? false, new: false))
            }
            line("lock.fill", reachesOffMac ? "Paused in local-only mode." : "Works in local-only mode.", tag: nil)
        }
    }

    private var hostList: String {
        let hosts = package.hosts + (package.settings.contains { $0.kind == .server } ? ["your server"] : [])
        return hosts.isEmpty ? "its server" : ListFormatter.localizedString(byJoining: hosts)
    }

    private var reachesOffMac: Bool {
        !package.hosts.isEmpty || package.settings.contains { setting in
            setting.kind == .server && !(URL(string: values["settings.\(setting.id)"] ?? "")?.host.map(PackageValidator.isLoopback) ?? false)
        }
    }

    private func article(_ word: String) -> String {
        "aeiouAEIOU".contains(word.first ?? "x") ? "an" : "a"
    }

    private func limitsLine(_ limits: PackageLimits) -> String {
        switch (limits.daily, limits.monthly) {
        case let (d?, m?): "Stops after \(d) searches a day or \(m) a month."
        case let (d?, nil): "Stops after \(d) searches a day."
        case let (nil, m?): "Stops after \(m) searches a month."
        default: "No limit."
        }
    }

    private func tag(changed: Bool, new: Bool) -> String? { new ? "New" : changed ? "Changed" : nil }

    private func line(_ symbol: String, _ text: String, tag: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(text).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let tag {
                    Text(tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)
            Divider()
        }
    }
}

// MARK: - Add, review, problems

/// One sheet with steps inside: Add, then Review or Problems. Back keeps what was pasted.
struct AddPackageSheet: View {
    let dismiss: () -> Void
    let added: (String) -> Void
    /// Open straight at the review of an installed package changed on disk.
    var reviewing: String?
    /// Open at the review (or problems) of this, as if it had been dropped in.
    var preload: (data: Data, origin: PackageStore.Origin)?

    enum Step: Equatable { case add, review, problems }

    struct Candidate {
        var data: Data
        var package: LassoPackage
        var origin: PackageStore.Origin
        var replacing: LassoPackage?
        var alreadyInstalled: String?
        var turnOn = false
    }

    @State private var step: Step = .add
    @State private var pasted = ""
    @State private var candidate: Candidate?
    @State private var problems: [PackageProblem] = []
    @State private var headline = "This package can't be added"
    @State private var detail: String? = "Fix these in the file, then try again."
    @State private var needsNewerLasso = false
    @State private var dropTargeted = false
    @State private var showFile = false
    private var store: PackageStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case .add: addStep
            case .review: reviewStep
            case .problems: problemsStep
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if let id = reviewing, let item = store.installed.first(where: { $0.id == id }), let data = store.manifestData(id) {
                candidate = Candidate(data: data, package: item.package, origin: item.origin,
                                      replacing: item.approved, turnOn: true)
                step = .review
            } else if let preload {
                consider(preload.data, origin: preload.origin)
            }
        }
    }

    // MARK: Add

    @ViewBuilder private var addStep: some View {
        Text("Add a Package").font(.title3.bold())
        let builtIn = BundledPackages.all().filter { !store.isInstalled($0.package.id) }
        if !builtIn.isEmpty {
            SettingsCard(title: "Built into Lasso") {
                ForEach(builtIn, id: \.package.id) { item in
                    SettingsRow(item.package.name, caption: item.package.summary) {
                        Button("Add…") { consider(item.data, origin: .bundled) }.buttonStyle(.bordered)
                    }
                }
            }
        }
        VStack(spacing: 10) {
            Text("Drop a .lasso.json file or package folder here").font(SettingsFont.label).foregroundStyle(.secondary)
            Button("Choose File…") { choose() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
            .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: 1.5, dash: dropTargeted ? [] : [5, 4])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in load(url) } }
            }
            return true
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Or paste the package's JSON").font(SettingsFont.sectionHeader)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pasted)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if pasted.isEmpty {
                    Text("{ \"lasso\": 1, \"id\": \"brave-search\", … }")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        }
        HStack {
            Spacer()
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Button("Review") { consider(Data(pasted.utf8), origin: .pasted) }
                .keyboardShortcut(.defaultAction)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .folder]
        panel.message = "Choose a .lasso.json file or a package folder"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    /// A `.lasso.json` file, or a folder with `lasso.json` in it.
    private func load(_ url: URL) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let file = isFolder.boolValue ? url.appending(path: "lasso.json") : url
        guard let data = try? Data(contentsOf: file) else {
            show(problems: [], headline: "This isn't a Lasso package.",
                 detail: "Use a .lasso.json file or a folder with a lasso.json inside.")
            return
        }
        consider(data, origin: .file)
    }

    private func consider(_ data: Data, origin: PackageStore.Origin) {
        needsNewerLasso = false
        if data.count > PackageValidator.maxManifestBytes {
            show(problems: [], headline: "This package is larger than 64 KB.", detail: nil); return
        }
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                show(problems: [], headline: "This isn't a Lasso package.",
                     detail: "Use a .lasso.json file or a folder with a lasso.json inside."); return
            }
        } catch {
            show(problems: [], headline: Self.jsonError(error), detail: nil); return
        }
        switch store.review(data) {
        case .success(let reviewed):
            candidate = Candidate(data: data, package: reviewed.package, origin: origin, replacing: reviewed.replacing)
            step = .review
        case .failure(.alreadyInstalled(let version)):
            guard let package = PackageValidator.validate(data).package else { return }
            let message = PackageValidator.isNewer(version, than: package.version)
                ? "A newer version, \(version), is already installed."
                : "\(package.name) \(package.version) is already installed."
            candidate = Candidate(data: data, package: package, origin: origin, alreadyInstalled: message)
            step = .review
        case .failure(.invalid(let list)):
            if list.contains(where: { $0.path == "lasso" && $0.message.hasPrefix("Needs a newer Lasso") }) {
                needsNewerLasso = true
                show(problems: [], headline: "This package needs a newer version of Lasso.", detail: nil)
            } else {
                let notYet = list.filter { $0.message.contains("can't") && $0.message.contains("yet") }
                show(problems: notYet + list.filter { !notYet.contains($0) },
                     headline: "This package can't be added", detail: "Fix these in the file, then try again.")
            }
        }
    }

    /// "This isn't valid JSON (line 4, column 12)." when Foundation says where.
    static func jsonError(_ error: Error) -> String {
        let debug = ((error as NSError).userInfo["NSDebugDescription"] as? String) ?? ""
        if let match = debug.firstMatch(of: #/line (\d+), column (\d+)/#) {
            return "This isn't valid JSON (line \(match.1), column \(match.2))."
        }
        return "This isn't valid JSON."
    }

    private func show(problems: [PackageProblem], headline: String, detail: String?) {
        self.problems = problems
        self.headline = headline
        self.detail = detail
        step = .problems
    }

    // MARK: Review

    @ViewBuilder private var reviewStep: some View {
        if let c = candidate {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identity(c)
                    if c.alreadyInstalled == nil {
                        PackagePermissionsList(package: c.package, compareTo: c.replacing,
                                               values: store.settingValues(for: c.package).values)
                        DisclosureGroup("Show the package file", isExpanded: $showFile) {
                            ScrollView(.horizontal) {
                                Text(String(decoding: c.data, as: UTF8.self))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 6)
                            }
                        }
                        .font(SettingsFont.label)
                    }
                }
            }
            .frame(maxHeight: 460)
            HStack {
                if !c.turnOn { Button("Back") { step = .add } }
                Spacer()
                if c.alreadyInstalled != nil {
                    Button("Open") { added(c.package.id) }
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button(c.turnOn ? "Turn On" : c.replacing == nil ? "Add" : "Update") { commit(c) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func identity(_ c: Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PackageIcon(package: c.package, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.package.name).font(.title3.bold())
                Text("By \(c.package.author) · Version \(c.package.version)").font(SettingsFont.label).foregroundStyle(.secondary)
                originLine(c.origin)
                Text(c.package.summary).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                if let message = c.alreadyInstalled {
                    Text(message).font(SettingsFont.label).foregroundStyle(.secondary)
                } else if c.turnOn, let old = c.replacing {
                    Text("Its file changed outside Lasso. Compared with version \(old.version) you approved, changes are tagged below.")
                        .font(SettingsFont.sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.identityChanges(from: old, to: c.package), id: \.self) { change in
                        Text(change).font(SettingsFont.sub).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let old = c.replacing {
                    Text("Updates \(old.name) from \(old.version) to \(c.package.version). Your key and settings are kept.")
                        .font(SettingsFont.sub).foregroundStyle(.secondary)
                    ForEach(Self.identityChanges(from: old, to: c.package).filter { !$0.hasPrefix("Version") }, id: \.self) { change in
                        Text(change).font(SettingsFont.sub).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What it calls itself changed (a package renaming itself is worth seeing).
    static func identityChanges(from old: LassoPackage, to new: LassoPackage) -> [String] {
        var out: [String] = []
        if old.name != new.name { out.append("Name changed from \"\(old.name)\".") }
        if old.author != new.author { out.append("Author changed from \"\(old.author)\".") }
        if old.summary != new.summary { out.append("Description changed from \"\(old.summary)\".") }
        if old.version != new.version { out.append("Version changed from \(old.version).") }
        return out
    }

    @ViewBuilder private func originLine(_ origin: PackageStore.Origin) -> some View {
        switch origin {
        case .bundled, .catalog:
            Text(origin == .bundled ? "Built into Lasso" : "From the Lasso catalog").font(SettingsFont.sub).foregroundStyle(.secondary)
        case .file, .pasted:
            Label("\(origin == .file ? "From a file" : "Pasted"). Anyone can make a package and the author's name isn't checked. Only add packages from people you trust.",
                  systemImage: "exclamationmark.triangle")
                .font(SettingsFont.sub).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit(_ c: Candidate) {
        if c.turnOn {
            store.approveChange(c.package.id)
            added(c.package.id)
            return
        }
        do {
            let package = try store.install(c.data, origin: c.origin)
            added(package.id)
        } catch {
            show(problems: (error as? PackageStore.InstallError).flatMap { if case .invalid(let p) = $0 { p } else { nil } } ?? [],
                 headline: "This package can't be added", detail: error.localizedDescription)
        }
    }

    // MARK: Problems

    @ViewBuilder private var problemsStep: some View {
        Text(headline).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
        if let detail { Text(detail).font(SettingsFont.label).foregroundStyle(.secondary) }
        if !problems.isEmpty {
            ScrollView {
                SettingsCard(title: "") {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(problem.message).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                                if !problem.path.isEmpty {
                                    Text(problem.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        HStack {
            if !problems.isEmpty {
                Button("Copy Problems") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(problems.map(\.description).joined(separator: "\n"), forType: .string)
                }
            }
            if needsNewerLasso {
                Button("Check for Updates") { AppUpdater.shared.checkForUpdates() }.disabled(PrivacyMode.localOnly)
            }
            Spacer()
            Button("Back") { step = .add }
            Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Package page

struct PackagePage: View {
    let id: String
    let localOnly: Bool
    let removed: () -> Void

    @State private var reviewing = false
    @State private var confirmRemove = false
    @State private var test: TestState = .idle
    @State private var usageTick = 0
    private var store: PackageStore { .shared }

    enum TestState: Equatable {
        case idle, running
        case ok(count: Int, ms: Int, hits: [String])
        case failed(String)
    }

    var body: some View {
        SettingsPage {
            if let item = store.installed.first(where: { $0.id == id }) {
                content(item)
            } else if let broken = store.broken.first(where: { $0.id == id }) {
                brokenContent(broken)
            } else {
                Text("This package isn't installed.").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $reviewing) {
            AddPackageSheet(dismiss: { reviewing = false }, added: { _ in reviewing = false }, reviewing: id)
        }
    }

    @ViewBuilder private func content(_ item: PackageStore.Installed) -> some View {
        let package = item.package
        header(package, origin: item.origin)
        if item.changedOnDisk {
            SettingsCard(title: "") {
                SettingsRow("Its file changed outside Lasso. Review the changes to turn it back on.") {
                    Button("Review…") { reviewing = true }.buttonStyle(.bordered)
                }
            }
        } else {
            SettingsCard(title: "") {
                SettingsRow("Use \(package.name)", caption: package.commands.first.map(PackageStatus.roleLine)) {
                    SettingsSwitch(title: "", isOn: Binding(get: { item.enabled }, set: { store.setEnabled(id, $0); test = .idle }))
                        .disabled(PackageStatus.of(item, localOnly: localOnly).switchDisabled)
                }
            }
        }
        if !package.settings.isEmpty {
            SettingsCard(title: "Settings") {
                ForEach(package.settings, id: \.id) { setting in
                    PackageSettingRow(packageID: id, packageName: package.name, setting: setting,
                                      changed: { test = .idle })
                }
            }
        }
        if let limits = package.limits { usage(package, limits) }
        if let command = package.commands.first(where: { $0.surfaces.contains(.search) }) { testCard(item, command) }
        PackagePermissionsList(package: package, values: store.settingValues(for: package).values)
        removeCard(package)
    }

    @ViewBuilder private func brokenContent(_ broken: PackageStore.Broken) -> some View {
        SettingsCard(title: "This package can't be used", footnote: "Fix its file, or remove it.") {
            ForEach(Array(broken.problems.enumerated()), id: \.offset) { _, problem in
                SettingsRow(problem.message, caption: problem.path) { EmptyView() }
            }
        }
        SettingsCard(title: "") {
            SettingsRow("Remove this package") {
                Button("Remove…", role: .destructive) { confirmRemove = true }.buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Remove \(broken.id)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove(broken.id); removed() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func header(_ package: LassoPackage, origin: PackageStore.Origin) -> some View {
        VStack(spacing: 8) {
            PackageIcon(package: package, size: 56)
            Text(package.name).font(.title2.bold())
            Text(package.summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Version \(package.version) · By \(package.author) · \(Self.originText(origin))")
                .font(SettingsFont.sub).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
            .strokeBorder(SettingsPalette.cardBorder, lineWidth: 1))
    }

    static func originText(_ origin: PackageStore.Origin) -> String {
        switch origin {
        case .bundled: "Built into Lasso"
        case .catalog: "From the Lasso catalog"
        case .file: "From a file"
        case .pasted: "Pasted"
        }
    }

    private func usage(_ package: LassoPackage, _ limits: PackageLimits) -> some View {
        let _ = usageTick
        let today = SearchQuota.usedToday(package.id), month = SearchQuota.usedMonth(package.id)
        return SettingsCard(title: "Usage", footnote: "Counted on this Mac. Resets at midnight and on the 1st.") {
            if let daily = limits.daily { usageRow("Today", today, daily) }
            if let monthly = limits.monthly { usageRow("This month", month, monthly) }
        }
    }

    private func usageRow(_ label: String, _ used: Int, _ limit: Int) -> some View {
        SettingsRow(label) {
            Text("\(used) of \(limit)").font(SettingsFont.label)
                .foregroundStyle(used >= limit ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private func testCard(_ item: PackageStore.Installed, _ command: PackageCommand) -> some View {
        let package = item.package
        let status = PackageStatus.of(item, localOnly: localOnly)
        let blocked: String? = item.changedOnDisk ? "Review its changes first."
            : status.switchDisabled ? "Paused in local-only mode."
            : store.missingSettings(package).contains { $0.kind == .secret } ? "Add your API key first."
            : !store.missingSettings(package).isEmpty ? "Fill in its settings first."
            : !SearchQuota.canUse(package.id, limits: package.limits) ? "Limit reached."
            : nil
        return SettingsCard(title: "Test") {
            SettingsRow("Test", caption: blocked ?? "Searches for \"\(command.testQuery ?? "lasso")\". Counts as one search.") {
                switch test {
                case .running: SettingsStatusChip(text: "Testing…", tint: .secondary, busy: true)
                case .ok(let count, let ms, _): SettingsStatusChip(text: "\(count) result\(count == 1 ? "" : "s") in \(ms) ms", tint: .green)
                case .failed(let reason): SettingsStatusChip(text: reason, tint: .orange)
                case .idle: EmptyView()
                }
                Button("Test") { runTest(package, command) }
                    .buttonStyle(.bordered)
                    .disabled(blocked != nil || test == .running)
            }
            if case .ok(_, _, let hits) = test {
                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                    let parts = hit.components(separatedBy: "\n")
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts[0]).font(SettingsFont.label).lineLimit(1)
                            if parts.count > 1 { Text(parts[1]).font(SettingsFont.sub).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }

    private func runTest(_ package: LassoPackage, _ command: PackageCommand) {
        let s = store.settingValues(for: package)
        let entry = PackageRegistry.Entry(package: package, values: s.values, secrets: s.secrets, ready: true)
        test = .running
        let started = Date()
        Task {
            let result = await PackageSearch.test(entry, command)
            usageTick += 1
            switch result {
            case .success(let hits):
                test = .ok(count: hits.count, ms: Int(Date().timeIntervalSince(started) * 1000),
                           hits: hits.prefix(3).map { "\($0.title)\n\($0.url?.host ?? "")" })
            case .failure(let error):
                test = .failed(PackageHTTP.redact(error.localizedDescription, secrets: s.secrets))
            }
        }
    }

    private func removeCard(_ package: LassoPackage) -> some View {
        SettingsCard(title: "") {
            if let homepage = package.homepage {
                SettingsRow("Homepage") { Link(homepage.host ?? homepage.absoluteString, destination: homepage) }
            }
            SettingsRow("Remove \(package.name) from Lasso") {
                Button("Remove \(package.name)…", role: .destructive) { confirmRemove = true }.buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Remove \(package.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove(package.id); removed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings and API key are deleted from this Mac. This month's usage count is kept.")
        }
    }
}

/// One setting of a package. Typing is saved a moment after it stops (a key isn't written to the
/// Keychain per keystroke).
private struct PackageSettingRow: View {
    let packageID: String
    let packageName: String
    let setting: PackageSetting
    let changed: () -> Void

    @State private var text = ""
    @State private var save: Task<Void, Never>?
    @Environment(\.openURL) private var openURL
    private var store: PackageStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: SettingsMetrics.columnGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.label).font(SettingsFont.label)
                    if let caption {
                        Text(caption.text).font(SettingsFont.sub)
                            .foregroundStyle(caption.warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let help = setting.help {
                        Button(setting.kind == .secret ? "Get a key" : "Help") { openURL(help) }
                            .buttonStyle(.link).font(SettingsFont.sub)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control.layoutPriority(1)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, SettingsMetrics.rowPaddingV)
            Divider()
        }
        .onAppear { text = store.value(packageID, setting) }
        .onDisappear { commit() }
    }

    private var caption: (text: String, warn: Bool)? {
        switch setting.kind {
        case .secret where text.isEmpty: ("Required. Searches skip \(packageName) until it's added.", true)
        case .server:
            if text.isEmpty { ("Searches are sent here.", false) }
            else if let url = URL(string: text), let host = url.host,
                    url.scheme == "https" || (url.scheme == "http" && PackageValidator.isLoopback(host)) { ("Searches are sent here.", false) }
            else { ("Use https, or http only for this Mac.", true) }
        default: nil
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .secret:
            SettingsKeyField(text: $text, placeholder: setting.label, onClear: { text = "" })
                .settingsFieldWidth()
                .onChange(of: text) { _, _ in later() }
        case .text, .server, .folder:
            TextField("", text: $text, prompt: Text(setting.kind == .server ? "http://localhost:8888" : ""))
                .textFieldStyle(.roundedBorder)
                .settingsFieldWidth()
                .onSubmit(commit)
                .onChange(of: text) { _, _ in later() }
        case .choice:
            Picker("", selection: Binding(get: { text }, set: { text = $0; commit() })) {
                ForEach(setting.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().settingsCappedMenu()
        case .toggle:
            SettingsSwitch(title: "", isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false"; commit() }))
        }
    }

    private func later() {
        save?.cancel()
        save = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { commit() }
        }
    }

    private func commit() {
        save?.cancel()
        guard text != store.value(packageID, setting) else { return }
        if setting.kind == .server, !text.isEmpty, caption?.warn == true { return }
        store.setValue(text, packageID, setting)
        changed()
    }
}
