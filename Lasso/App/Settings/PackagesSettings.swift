import AppKit
import KeyboardShortcuts
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
        if let folder = store.missingSettings(package).first(where: { $0.kind == .folder }) {
            return PackageStatus(text: "Choose its \(folder.label.lowercased())", needsAction: true)
        }
        if !store.missingSettings(package).isEmpty {
            return PackageStatus(text: "Needs setting up", needsAction: true)
        }
        if let why = PackageRequirements.missingNow(package) {
            return PackageStatus(text: String(why.prefix { $0 != "." }), needsAction: true)
        }
        if let shortcut = package.commands.compactMap(\.shortcut).first(where: { PackageShortcut.isInstalledNow($0.name) == false }) {
            return PackageStatus(text: "Get the Shortcut “\(shortcut.name)”", needsAction: true)
        }
        let today = usedToday ?? SearchQuota.usedToday(package.id)
        let month = usedMonth ?? SearchQuota.usedMonth(package.id)
        if let daily = package.limits?.daily, today >= daily {
            return PackageStatus(text: "Daily limit reached. Back tomorrow", needsAction: false)
        }
        if let monthly = package.limits?.monthly, month >= monthly {
            return PackageStatus(text: "Monthly limit reached. Back on \(firstOfNextMonth(now))", needsAction: false)
        }
        guard package.commands.contains(where: { $0.surfaces.contains(.search) }) else {
            // Where another package's change is used instead of this one's, say whose.
            let replacedBy = package.patches.compactMap { store.patches.winner[$0.target] }.first { $0 != package.id }
            if let replacedBy, let name = store.installed.first(where: { $0.id == replacedBy })?.package.name {
                return PackageStatus(text: surfacesSummary(package) + " · Partly replaced by \(name)", needsAction: false)
            }
            return PackageStatus(text: surfacesSummary(package) + (store.hasFullAccess(package.id) ? " · Full access" : ""), needsAction: false)
        }
        let role = package.commands.contains { $0.surfaces.contains(.search) && $0.searchRole == .primary } ? "Every search" : "When results are thin"
        if let monthly = package.limits?.monthly { return PackageStatus(text: "\(role) · \(month) of \(monthly) this month", needsAction: false) }
        return PackageStatus(text: role, needsAction: false)
    }

    /// "Toolbar · /explain · Send to · Hotkey": where a package's commands show.
    static func surfacesSummary(_ package: LassoPackage) -> String {
        var parts: [String] = package.patches.isEmpty ? [] : ["Changes Lasso"]
        func add(_ part: String) { if !parts.contains(part) { parts.append(part) } }
        for command in package.commands {
            for surface in command.surfaces {
                switch surface {
                case .toolbar: add("Toolbar")
                case .send: add("Send to")
                case .slash: add("/\(command.id)")
                case .hotkey: add("Hotkey")
                case .tool: add("Tool")
                case .event: add("Runs by itself")
                default: break
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    static func firstOfNextMonth(_ now: Date) -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return next.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The command's role, in words (review, page caption).
    static func roleLine(_ command: PackageCommand) -> String {
        if let script = command.script, !script.network { return "Searched when you type @ and its name, or a message fits it" }
        return command.searchRole == .primary ? "Adds results to every web search" : "Adds results when web search comes back thin"
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
    @State private var browsing = false
    @AppStorage("packages.developerMode") private var developerMode = false
    private var store: PackageStore { .shared }
    private var catalog: PackageCatalog { .shared }

    private var sorted: [PackageStore.Installed] {
        store.installed.sorted { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }
    }
    private func isSearch(_ item: PackageStore.Installed) -> Bool {
        item.package.commands.contains { $0.surfaces.contains(.search) }
    }

    /// A search package that never leaves this Mac (My notes): a source, not part of web search.
    private func isOnThisMac(_ item: PackageStore.Installed) -> Bool {
        let entry = PackageRegistry.Entry(package: item.package, values: store.settingValues(for: item.package).values,
                                          secrets: [], ready: true)
        return item.package.commands.contains { $0.surfaces.contains(.search) && PackageSource.isOnThisMac(entry, $0) }
    }

    var body: some View {
        let local = sorted.filter { isSearch($0) && isOnThisMac($0) }
        let search = sorted.filter { isSearch($0) && !isOnThisMac($0) }, others = sorted.filter { !isSearch($0) }
        SettingsPage {
            SettingsHubHeader(pane: .packages)
            Label {
                Text("In chat, type **@** to search a source, **/** to run a command.").font(SettingsFont.sub)
            } icon: { Image(systemName: "lightbulb") }
            .foregroundStyle(.secondary).padding(.horizontal, 2)
            if !local.isEmpty {
                SettingsCard(title: "On this Mac",
                             footnote: "Lasso looks in these when a message fits, or when you type @ and the name. Only matches go to your chat model.") {
                    ForEach(local) { row($0) }
                }
            }
            SettingsCard(title: "Web search",
                         footnote: localOnly ? "Paused in local-only mode."
                             : "Used when the globe is on. Lasso rewrites your question and sends it to these. Every search adds results first; the rest fill in when results are thin.") {
                webSearchRow
                ForEach(search) { row($0) }
                if others.isEmpty {
                    ForEach(store.broken) { brokenRow($0) }
                    if store.installed.isEmpty, store.broken.isEmpty { emptyRow }
                    addStrip
                }
            }
            if !others.isEmpty {
                SettingsCard(title: "Buttons and commands") {
                    ForEach(others) { row($0) }
                    ForEach(store.broken) { brokenRow($0) }
                    addStrip
                }
            }
            if !tools.isEmpty { toolsCard }
            SettingsCard(title: "", footnote: localOnly ? "Off in local-only mode: browsing reads the catalog from GitHub." : nil) {
                SettingsRow("Lasso package catalog", symbol: "square.grid.2x2",
                            caption: updatesCount > 0 ? "\(updatesCount) update\(updatesCount == 1 ? "" : "s") available"
                                : "Packages anyone can share, checked before they're listed.") {
                    Button("Browse…") { browsing = true }.buttonStyle(.bordered).disabled(localOnly)
                }
            }
            PackageDeveloperCard(on: $developerMode, openPackage: openPackage)
        }
        .sheet(isPresented: $adding) {
            AddPackageSheet(dismiss: { adding = false }, added: { id in adding = false; openPackage(id) })
        }
        .sheet(isPresented: $browsing, onDismiss: { catalog.requested = nil }) {
            PackageBrowseSheet(dismiss: { browsing = false }, added: { id in browsing = false; openPackage(id) },
                               focus: catalog.requested)
        }
        .onAppear { if catalog.requested != nil { browsing = true }; store.watchDeveloperFolders() }
        .onChange(of: catalog.requested) { _, id in if id != nil { browsing = true } }
    }

    /// Updates found the last time the catalog was read (it's only read when the user asks).
    private var updatesCount: Int { catalog.updates(store.installed).count }

    /// Every enabled package's tools, whether turned off here or not.
    private var tools: [PackageRegistry.Tool] {
        let _ = store.installed   // re-read when packages change
        return PackageRegistry.shared.tools(localOnly: localOnly)
    }

    /// Which tools models are offered, against the budget: every description is read with every request.
    private var toolsCard: some View {
        let used = PackageRegistry.shared.toolBudgetUsed(localOnly: localOnly)
        return SettingsCard(title: "Tools for models",
                            footnote: "The chat model (if it supports tools) is offered the 3 that fit each message best. The Agent gets them all "
                                + "within \(PackageRegistry.toolBudget.formatted()) characters of descriptions: \(used.formatted()) used.") {
            ForEach(tools, id: \.name) { tool in
                SettingsRow(tool.command.title,
                            caption: tool.notOffered ?? "\(tool.entry.package.name) · \(tool.name)"
                                + (PackageToolCall.needsApproval(tool.command) ? " · asks first" : "")) {
                    SettingsSwitch(title: "", isOn: Binding(
                        get: { store.isToolOffered(tool.entry.package.id, tool.command.id) },
                        set: { store.setToolOffered(tool.entry.package.id, tool.command.id, $0) }))
                }
            }
        }
    }

    private func row(_ item: PackageStore.Installed) -> some View {
        PackageRow(icon: PackageIcon(package: item.package), name: item.package.name,
                   status: PackageStatus.of(item, localOnly: localOnly),
                   isOn: Binding(get: { item.enabled }, set: { store.setEnabled(item.id, $0) }),
                   open: { openPackage(item.id) })
    }

    private func brokenRow(_ broken: PackageStore.Broken) -> some View {
        PackageRow(icon: PackageIcon(package: nil), name: broken.id,
                   status: PackageStatus(text: "Can't be used: \(broken.problems.count) problem\(broken.problems.count == 1 ? "" : "s")",
                                         needsAction: true, hidesSwitch: true),
                   isOn: .constant(false), open: { openPackage(broken.id) })
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
                Text("No packages yet. Add Tavily or SerpApi for stronger search results, or a package file for new buttons and commands.")
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
    /// Off on a package's page when its Commands card already says where each command shows.
    var showsWhatItDoes = true
    /// The version it replaces or was approved as: what's new is tagged.
    var compareTo: LassoPackage?
    var values: [String: String] = [:]
    /// Files that differ from the installed version (an update's changed scripts).
    var changedFiles: [String] = []
    /// The user gave its scripts full access (shown on its page).
    var fullAccess = false

    var body: some View {
        if showsWhatItDoes, !package.commands.isEmpty || !(compareTo?.commands.isEmpty ?? true) { SettingsCard(title: "What it does") {
            ForEach(package.commands, id: \.id) { command in
                line(command.surfaces.contains(.search) ? "magnifyingglass" : (command.symbol ?? "shippingbox"),
                     PackagePermissionsList.doesLine(command),
                     tag: tag(changed: compareTo.map { old in old.command(command.id)?.http?.role != command.http?.role } ?? false,
                              new: compareTo.map { $0.command(command.id) == nil } ?? false))
            }
            if let old = compareTo {
                ForEach(old.commands.filter { package.command($0.id) == nil }, id: \.id) { gone in
                    line("minus.circle", "No longer: \(gone.title)", tag: nil)
                }
            }
        } }
        if !package.patches.isEmpty { PackageChangesCard(package: package, compareTo: compareTo) }
        SettingsCard(title: "What it can reach") {
            if package.commands.contains(where: { $0.prompt != nil }) {
                line("cpu", Self.modelLine, tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.prompt != nil } } ?? false))
            }
            ForEach(package.hosts, id: \.self) { host in
                line("network", package.commands.allSatisfy { $0.surfaces.contains(.search) }
                         ? "Sends your searches to \(host)"
                         : package.commands.contains { $0.http != nil && $0.output != .open } ? "Sends the text you run it on to \(host)" : "Opens pages on \(host) in your browser",
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
            codeLines
            if package.commands.contains(where: { $0.surfaces.contains(.search) && $0.script.map { !$0.network } == true }) {
                line("arrow.up.message", "Sends the matching passages to your chat model. With a cloud model they leave this Mac, after you allow it.",
                     tag: nil)
            }
            if package.commands.contains(where: { $0.hook == .source }) {
                line("text.bubble", "Reads your message and your previous question when it searches",
                     tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.hook == .source } } ?? false))
            }
            if package.commands.contains(where: \.ranks) {
                line("line.3.horizontal.decrease", "Picks its own best results instead of Lasso's word match",
                     tag: tag(changed: false, new: compareTo.map { !$0.commands.contains(where: \.ranks) } ?? false))
            }
            if package.commands.contains(where: { $0.input.contains(.source) }) {
                line("app.badge", "Sees which app the text came from", tag: nil)
            }
            if package.commands.contains(where: { $0.input.contains(.image) }) {
                line("photo", "Sees the image you lasso", tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.input.contains(.image) } } ?? false))
            }
            if package.commands.contains(where: { $0.input.contains(.lines) }) {
                line("text.viewfinder", "Sees the text you lasso and where each piece sits", tag: nil)
            }
            if let events = Optional(package.commands.filter { $0.surfaces.contains(.event) }), !events.isEmpty {
                let on = Set(events.flatMap(\.on)).map { $0 == .capture ? "every capture" : "every chat reply" }.sorted().joined(separator: " and ")
                line("bolt", "Can run by itself on \(on), only if you turn that on. It's off until you do.",
                     tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.surfaces.contains(.event) } } ?? false))
            }
            if package.commands.contains(where: { $0.surfaces.contains(.tool) }) {
                line("wrench.and.screwdriver", Self.toolLine(package),
                     tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.surfaces.contains(.tool) } } ?? false))
            }
            if let overflow = Self.toolOverflow(package) {
                line("exclamationmark.triangle", overflow, tag: nil)
            }
            if package.commands.contains(where: { $0.output == .replace }) {
                line("text.cursor", "Pastes over your highlighted text", tag: nil)
            }
            if package.commands.contains(where: { $0.output == .open }) {
                line("arrow.up.forward.square", "Opens pages in your browser", tag: nil)
            }
            if package.commands.contains(where: { $0.output == .copy }) {
                line("doc.on.doc", "Copies results to your clipboard", tag: nil)
            }
            if let limits = package.limits {
                line("gauge.with.needle", limitsLine(limits), tag: tag(changed: compareTo.map { $0.limits != limits } ?? false, new: false))
            }
            if package.commands.isEmpty, package.hosts.isEmpty {
                line("checkmark.shield", "Nothing: it only changes Lasso itself, and sends nothing anywhere.", tag: nil)
            } else {
            line("lock.fill", localOnlyLine, tag: nil)
            }
        }
    }

    /// Scripts, Shortcuts, folders and what must be installed.
    @ViewBuilder private var codeLines: some View {
        let scripts = package.commands.compactMap(\.script)
        let hadScripts = compareTo.map { $0.commands.contains { $0.script != nil } }
        if !scripts.isEmpty {
            line("terminal", fullAccess
                    ? "Runs code on your Mac with full access: its scripts can do anything your account can."
                    : "Runs code on your Mac, in a sandbox: its scripts can't read your files"
                        + (package.settings.contains { $0.kind == .folder } ? " except a folder you choose" : "")
                        + ", and can change only their own folders.",
                 tag: tag(changed: false, new: hadScripts == false))
            if scripts.contains(where: \.network) {
                line("network", "Its scripts can reach the internet. The sandbox can't limit them to particular sites.",
                     tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.script?.network == true } } ?? false))
            }
        }
        if !changedFiles.isEmpty {
            line("doc.badge.gearshape", "Changed: " + changedFiles.joined(separator: ", "), tag: "Changed")
            if PackageStore.shared.hasFullAccess(package.id), changedFiles.contains(where: { $0.hasPrefix("scripts/") }) {
                line("exclamationmark.shield", "Full access will be turned off, because a script changed. You can turn it on again.", tag: nil)
            }
        }
        ForEach(package.commands.compactMap(\.shortcut), id: \.name) { shortcut in
            line("square.on.square", "Runs your Shortcut “\(shortcut.name)”, with your permissions. "
                    + (shortcut.offline ? "Its author says it works offline; Lasso can't check that." : "It can reach the internet."),
                 tag: tag(changed: false, new: compareTo.map { !$0.commands.contains { $0.shortcut?.name == shortcut.name } } ?? false))
        }
        ForEach(package.settings.filter { $0.kind == .folder }, id: \.id) { setting in
            line("folder", "Reads a folder you choose: \(setting.label). Only that folder.",
                 tag: tag(changed: false, new: compareTo.map { $0.setting(setting.id) == nil } ?? false))
        }
        // Only what's missing: an installed tool isn't worth a line.
        ForEach(Array(package.requires.enumerated()), id: \.offset) { _, requirement in
            if PackageRequirements.missingNow(LassoPackage(id: "", version: "", name: "", summary: "", author: "", hosts: [], settings: [],
                                                           commands: [], requires: [requirement])) != nil {
                line("shippingbox", PackageRequirements.sentence(requirement), tag: "Missing")
            }
        }
    }

    /// Where a prompt's text goes: the model chosen in Settings, said plainly (it follows the setting).
    @MainActor static var modelLine: String {
        let intelligence = IntelligenceCoordinator.shared
        let local = intelligence.effectivePreferred.isLocalKind
        // "MLX · Qwen3.5-9B…" rather than the whole Hugging Face id with its organisation.
        let label = intelligence.textEngineLabel.replacingOccurrences(of: "[^ ·/]+/", with: "", options: .regularExpression)
        return "Sends the text you run it on to your language model, chosen in Settings › Models. Now that's "
            + "\(label), \(local ? "on this Mac." : "in the cloud. Your text leaves your Mac.")"
    }

    /// What a model can do with the package's tools, and when Lasso asks.
    static func toolLine(_ package: LassoPackage) -> String {
        let tools = package.commands.filter { $0.surfaces.contains(.tool) }
        let asking = tools.filter(PackageToolCall.needsApproval)
        let base = "The chat model and the Agent can run \(tools.count == 1 ? "it" : "its tools")."
        if asking.isEmpty { return base + " \(tools.count == 1 ? "It only returns" : "They only return") text, so Lasso doesn't ask." }
        if asking.count == tools.count { return base + " Lasso asks you every time." }
        return base + " Lasso asks you before \(ListFormatter.localizedString(byJoining: asking.map(\.title)))."
    }

    /// Said in the review when adding the package would put the offered tools past the budget.
    @MainActor static func toolOverflow(_ package: LassoPackage, registry: PackageRegistry = .shared) -> String? {
        guard !PackageStore.shared.isInstalled(package.id) else { return nil }
        let adding = package.commands.compactMap(\.tool).reduce(0) { $0 + $1.description.count }
        guard adding > 0 else { return nil }
        let total = registry.toolBudgetUsed() + adding
        guard total > PackageRegistry.toolBudget else { return nil }
        return "Adds \(adding.formatted()) characters to your tools, past the \(PackageRegistry.toolBudget.formatted()) limit. "
            + "Some tools won't be offered until you turn others off in Settings › Packages."
    }

    /// One sentence for where a command appears.
    static func doesLine(_ command: PackageCommand) -> String {
        if command.hook == .describe { return "\(command.title): tells Lasso what's in your folder, so it knows when to look there" }
        if command.surfaces.contains(.search) { return PackageStatus.roleLine(command) }
        var places: [String] = []
        for surface in command.surfaces {
            switch surface {
            case .toolbar:
                let when = ActionBarCatalog.whenPhrase(command.when).replacingOccurrences(of: " · ", with: "")
                places.append("in the capture toolbar" + (when.isEmpty ? "" : " (\(when))"))
            case .send: places.append("in Send to, on captures and chat replies")
            case .slash: places.append("as /\(command.id) in chat")
            case .hotkey: places.append("on text you highlight, with a hotkey you set")
            case .event:
                places.append("by itself on " + command.on.map { $0 == .capture ? "every capture" : "every chat reply" }.joined(separator: " and ")
                              + ", once you allow it")
            case .tool:
                places.append("as a tool the chat model and the Agent can use"
                    + (PackageToolCall.needsApproval(command) ? ", asking you first" : ""))
            default: break
            }
        }
        return "\(command.title): " + (places.count > 1 ? places.dropLast().joined(separator: ", ") + ", and " + places.last! : places.joined())
    }

    private var hostList: String {
        let hosts = package.hosts + (package.settings.contains { $0.kind == .server } ? ["your server"] : [])
        return hosts.isEmpty ? "its server" : ListFormatter.localizedString(byJoining: hosts)
    }

    /// What local-only mode does to it.
    private var localOnlyLine: String {
        var parts: [String] = []
        if reachesOffMac { parts.append(package.commands.contains { $0.prompt != nil || $0.script != nil } ? "Its web requests pause in local-only mode." : "Paused in local-only mode.") }
        if package.commands.contains(where: { $0.shortcut.map { !$0.offline } ?? false }) { parts.append("Its Shortcut pauses in local-only mode.") }
        else if package.commands.contains(where: { $0.shortcut?.offline == true }) { parts.append("Its Shortcut runs in local-only mode, on its author's word that it's offline.") }
        if package.commands.contains(where: { $0.script?.network == true }) { parts.append("In local-only mode its scripts run without the internet.") }
        if parts.isEmpty { return package.commands.contains { $0.prompt != nil } ? "Works in local-only mode while your model is on this Mac." : "Works in local-only mode." }
        return parts.joined(separator: " ")
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
    /// The files that came with `preload` (a catalog package's scripts).
    var preloadFiles: PackageFiles.Files = [:]
    /// Where Back goes from the review, when not to the Add step (Browse).
    var back: (() -> Void)?

    enum Step: Equatable { case add, review, problems }

    struct Candidate {
        var data: Data
        /// The files beside the manifest in a package folder (its scripts).
        var files: PackageStore.Files = [:]
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
                candidate = Candidate(data: data, files: (try? PackageStore.readFiles(in: store.folder(id))) ?? [:],
                                      package: item.package, origin: item.origin, replacing: item.approved, turnOn: true)
                step = .review
            } else if let preload {
                consider(preload.data, files: preloadFiles, origin: preload.origin)
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
        panel.allowedContentTypes = [.json, .folder, .data]
        panel.message = "Choose a .lasso.json or .lassopkg file, or a package folder"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    /// A `.lasso.json` file, or a folder with `lasso.json` in it.
    private func load(_ url: URL) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if !isFolder.boolValue, url.pathExtension == PackageBundle.fileExtension {
            guard let bytes = try? Data(contentsOf: url), let unpacked = PackageBundle.unpack(bytes) else {
                show(problems: [], headline: "This .lassopkg file can't be read.", detail: nil); return
            }
            consider(unpacked.manifest, files: unpacked.files, origin: .file)
            return
        }
        let file = isFolder.boolValue ? url.appending(path: "lasso.json") : url
        guard let data = try? Data(contentsOf: file) else {
            show(problems: [], headline: "This isn't a Lasso package.",
                 detail: "Use a .lasso.json file or a folder with a lasso.json inside.")
            return
        }
        var files: PackageStore.Files = [:]
        if isFolder.boolValue {
            do { files = try PackageStore.readFiles(in: url) } catch {
                show(problems: (error as? PackageStore.InstallError).flatMap { if case .invalid(let p) = $0 { p } else { nil } } ?? [],
                     headline: "This package folder can't be added", detail: nil)
                return
            }
        }
        consider(data, files: files, origin: .file)
    }

    private func consider(_ data: Data, files: PackageStore.Files = [:], origin: PackageStore.Origin) {
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
        switch store.review(data, files: files) {
        case .success(let reviewed):
            candidate = Candidate(data: data, files: files, package: reviewed.package, origin: origin, replacing: reviewed.replacing)
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
                                               values: store.settingValues(for: c.package).values,
                                               changedFiles: c.replacing == nil ? [] : store.changedFiles(c.package.id, c.files))
                        PackageHowToCard(package: c.package)
                        DisclosureGroup(c.files.keys.contains { $0.hasPrefix("scripts/") } ? "Show the package file and scripts" : "Show the package file",
                                        isExpanded: $showFile) {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach([("lasso.json", c.data)] + c.files.filter { $0.key.hasPrefix("scripts/") }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                            id: \.0) { name, contents in
                                        Text(name).font(SettingsFont.sub.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(String(decoding: contents, as: UTF8.self))
                                            .font(.system(size: 11, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
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
                if !c.turnOn { Button("Back") { if let back { back() } else { step = .add } } }
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
            Text(origin == .bundled ? "Built into Lasso" : "From the Lasso catalog. Its scripts were read by a maintainer before it was listed.").font(SettingsFont.sub).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .developer:
            Text("Your own folder, in Developer mode. It reloads when you change its files.").font(SettingsFont.sub).foregroundStyle(.secondary)
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
            let package = try store.install(c.data, files: c.files, origin: c.origin)
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
            Button("Back") { if let back { back() } else { step = .add } }
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
    @State private var goBackError: String?
    @State private var confirmRemove = false
    @State private var confirmFullAccess = false
    @State private var confirmEvents = false
    /// Developer mode: which command the Test card runs.
    @State private var devCommand: String?
    /// The user's Shortcut names, read when the page opens (and on Check Again).
    @State private var shortcutNames: Set<String>?
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

    /// The package's search command as a source, with its settings now.
    private func source(_ item: PackageStore.Installed, _ command: PackageCommand) -> PackageSource? {
        let s = store.settingValues(for: item.package)
        let entry = PackageRegistry.Entry(package: item.package, values: s.values, secrets: s.secrets, ready: true,
                                          places: store.places(for: item.package), fullAccess: store.hasFullAccess(item.id))
        return PackageSource(entry: entry, command: command, isOnThisMac: PackageSource.isOnThisMac(entry, command))
    }

    @ViewBuilder private func content(_ item: PackageStore.Installed) -> some View {
        let package = item.package
        header(package, origin: item.origin)
        if !item.changedOnDisk { PackageHowToCard(package: package) }
        if item.changedOnDisk {
            SettingsCard(title: "") {
                SettingsRow("Its file changed outside Lasso. Review the changes to turn it back on.") {
                    Button("Review…") { reviewing = true }.buttonStyle(.bordered)
                }
            }
        } else {
            SettingsCard(title: "") {
                SettingsRow("Use \(package.name)",
                            caption: package.commands.allSatisfy { $0.surfaces.contains(.search) } ? package.commands.first.map(PackageStatus.roleLine) : nil) {
                    SettingsSwitch(title: "", isOn: Binding(get: { item.enabled }, set: { store.setEnabled(id, $0); test = .idle }))
                        .disabled(PackageStatus.of(item, localOnly: localOnly).switchDisabled)
                }
            }
        }
        if package.commands.contains(where: { !$0.surfaces.contains(.search) && $0.hook == nil }) {
            SettingsCard(title: "Commands") {
                // A source isn't a command: it has its own In chat card. Nor is a hook Lasso runs itself.
                ForEach(package.commands.filter { !$0.surfaces.contains(.search) && $0.hook == nil }, id: \.id) { command in
                    SettingsRow(command.title, symbol: command.symbol ?? package.iconSymbol ?? "shippingbox",
                                caption: Self.whereLine(package, command)) {
                        if package.commands.count > 1 {
                            SettingsSwitch(title: "", isOn: Binding(get: { store.isCommandEnabled(id, command.id) },
                                                                    set: { store.setCommandEnabled(id, command.id, $0) }))
                        }
                    }
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
        if item.origin == .developer { developerCard(package) }
        if let limits = package.limits { usage(package, limits) }
        if let command = package.commands.first(where: { $0.surfaces.contains(.search) }), let source = source(item, command), source.isOnThisMac {
            SourceSettingsCard(source: source)
            SourceTestCard(source: source, blocked: item.changedOnDisk ? "Review its changes first."
                           : store.missingSettings(package).first(where: { $0.kind == .folder }).map { "Choose its \($0.label.lowercased()) first." }
                           ?? PackageRequirements.missingNow(package) ?? (item.enabled ? nil : "Turn it on first."))
        }
        else if let command = package.commands.first(where: { $0.surfaces.contains(.search) }) { testCard(item, command) }
        else if item.origin == .developer, let command = package.command(devCommand ?? "") ?? package.commands.first {
            // Your own package: any command can be tried here, side effects included.
            commandTestCard(item, command)
        }
        else if let command = package.commands.first(where: Self.isSafeToTest) { commandTestCard(item, command) }
        if !package.commands.compactMap(\.shortcut).isEmpty { shortcutsCard(package) }
        PackagePermissionsList(package: package,
                               showsWhatItDoes: !package.commands.contains { !$0.surfaces.contains(.search) && $0.hook == nil },
                               values: store.settingValues(for: package).values,
                               fullAccess: store.hasFullAccess(id))
        if package.commands.contains(where: { $0.surfaces.contains(.event) }) { eventsCard(package) }
        if package.commands.contains(where: { $0.script != nil }) { fullAccessCard(package) }
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

    /// Developer mode: where it's loaded from, and what's wrong with the folder now (the last good
    /// copy keeps running meanwhile).
    private func developerCard(_ package: LassoPackage) -> some View {
        let problems = store.developerProblems[id] ?? []
        let source = store.developerSource(id)
        return SettingsCard(title: "Developer", footnote: problems.isEmpty
                                ? "Saved changes load within 2 seconds."
                                : "Lasso keeps running the last version without problems until these are fixed.") {
            SettingsRow("Loaded from", caption: source.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Unknown") {
                HStack(spacing: 8) {
                    Button("Show in Finder") { if let source { NSWorkspace.shared.activateFileViewerSelecting([source.appending(path: "lasso.json")]) } }
                    Button("Reload Now") { store.reloadChangedDeveloperFolders() }
                }
                .buttonStyle(.bordered)
            }
            if package.commands.filter({ !$0.surfaces.contains(.search) }).count > 1 {
                SettingsRow("Command to test") {
                    Picker("", selection: Binding(get: { devCommand ?? package.commands.first?.id ?? "" },
                                                  set: { devCommand = $0; test = .idle })) {
                        ForEach(package.commands.filter { !$0.surfaces.contains(.search) }, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().settingsCappedMenu()
                }
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                SettingsRow(problem.message, symbol: "exclamationmark.triangle", caption: problem.path.isEmpty ? nil : problem.path) { EmptyView() }
            }
        }
    }

    /// Each Shortcut it runs: whether the user has it, and where to get it.
    private func shortcutsCard(_ package: LassoPackage) -> some View {
        SettingsCard(title: "Shortcuts", footnote: "The package runs your own Shortcut, by its exact name. Rename it and the package can't find it.") {
            ForEach(package.commands.compactMap(\.shortcut), id: \.name) { shortcut in
                let has = shortcutNames?.contains(shortcut.name)
                SettingsRow("“\(shortcut.name)”", symbol: "square.on.square",
                            caption: has == nil ? "Checking…" : has! ? "In your Shortcuts" : "Not in your Shortcuts yet") {
                    if has == false {
                        HStack(spacing: 8) {
                            if let link = shortcut.get { Button("Get the Shortcut") { NSWorkspace.shared.open(link) }.buttonStyle(.bordered) }
                            Button("Check Again") { shortcutNames = nil; PackageShortcut.forget(); Task { shortcutNames = await PackageShortcut.installedNames() } }
                        }
                    }
                }
            }
        }
        .task { shortcutNames = await PackageShortcut.installedNames() }
    }

    /// Run automatically: the user's choice alone, per package, after saying what it means.
    private func eventsCard(_ package: LassoPackage) -> some View {
        let on = Set(package.commands.filter { $0.surfaces.contains(.event) }.flatMap(\.on))
            .map { $0 == .capture ? "every capture" : "every chat reply" }.sorted().joined(separator: " and ")
        return SettingsCard(title: "", footnote: PackageEvents.isAllowed(id)
                            ? "On: it runs on \(on) without a click, with what it can reach listed below."
                            : "Lets it run on \(on) without a click. Off until you turn it on.") {
            SettingsRow("Run automatically", symbol: "bolt") {
                SettingsSwitch(title: "", isOn: Binding(get: { PackageEvents.isAllowed(id) },
                                                        set: { on in if on { confirmEvents = true } else { PackageEvents.setAllowed(false, id); usageTick += 1 } }))
            }
        }
        .confirmationDialog("Let \(package.name) run by itself?", isPresented: $confirmEvents, titleVisibility: .visible) {
            Button("Run Automatically") { PackageEvents.setAllowed(true, id); usageTick += 1 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will run on \(on) without asking, and gets what it lists under What it can reach. An update that changes what runs turns this off again.")
        }
    }

    /// Full access: the user's choice alone, after saying what it means.
    private func fullAccessCard(_ package: LassoPackage) -> some View {
        SettingsCard(title: "", footnote: store.hasFullAccess(id)
                        ? "On: its scripts run without the sandbox. Lasso still stops them at their time limit. Local-only mode can't cut off their internet."
                        : "Turns off the sandbox for this package's scripts. Only for a package you trust.") {
            SettingsRow("Full access", symbol: "exclamationmark.shield") {
                SettingsSwitch(title: "", isOn: Binding(get: { store.hasFullAccess(id) },
                                                        set: { on in if on { confirmFullAccess = true } else { store.setFullAccess(id, false) } }))
            }
        }
        .confirmationDialog("Give \(package.name) full access?", isPresented: $confirmFullAccess, titleVisibility: .visible) {
            Button("Give Full Access", role: .destructive) { store.setFullAccess(id, true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This package's scripts can do anything your account can: read your files, reach the internet, run other programs. Lasso can't stop that, even in local-only mode. Turn it on only for a package you trust. An update that changes its scripts turns it off again.")
        }
    }

    /// Where a command appears, with its hotkey when it has one.
    static func whereLine(_ package: LassoPackage, _ command: PackageCommand) -> String {
        var parts: [String] = []
        if command.surfaces.contains(.search) { parts.append(PackageStatus.roleLine(command)) }
        if command.surfaces.contains(.toolbar) { parts.append("Toolbar\(ActionBarCatalog.whenPhrase(command.when))") }
        if command.surfaces.contains(.slash) { parts.append("/\(command.id) in chat") }
        if command.surfaces.contains(.send) { parts.append("Send to, on captures and chat replies") }
        if command.surfaces.contains(.event) {
            parts.append("Runs by itself on " + command.on.map { $0 == .capture ? "captures" : "chat replies" }.joined(separator: " and "))
        }
        if command.surfaces.contains(.hotkey) {
            let key = KeyboardShortcuts.getShortcut(for: PackageHotkeys.name(package.id, command.id))?.description
            parts.append("Hotkey: \(key ?? "not set, in Settings › Keyboard Shortcuts")")
        }
        if command.surfaces.contains(.tool) {
            let tool = PackageRegistry.shared.tools(localOnly: false).first { $0.entry.package.id == package.id && $0.command.id == command.id }
            parts.append("Tool \(tool?.name ?? command.tool?.name ?? "")" + (PackageToolCall.needsApproval(command) ? ", asks first" : ""))
        }
        return parts.joined(separator: " · ")
    }

    /// Test only what has no side effects: a prompt, a GET, or an `open` (shown, not opened). A POST
    /// could create a real task or send a real message.
    static func isSafeToTest(_ command: PackageCommand) -> Bool {
        guard command.hook == nil else { return false }
        return command.prompt != nil || (command.http?.method == "GET" && command.output != .notify)
            || (command.script.map { !$0.network } == true && command.output == .markdown)
    }

    private func commandTestCard(_ item: PackageStore.Installed, _ command: PackageCommand) -> some View {
        let package = item.package
        let sample = command.testText ?? "Lasso is a Mac app that reads, translates and explains whatever you select on screen."
        let blocked: String? = item.changedOnDisk ? "Review its changes first."
            : PackageStatus.of(item, localOnly: localOnly).switchDisabled && command.http != nil ? "Paused in local-only mode."
            : store.missingSettings(package).contains { $0.kind == .secret } ? "Add your API key first."
            : nil
        return SettingsCard(title: "Test") {
            SettingsRow("Test \(command.title)", caption: blocked ?? "Runs on sample text\(command.http != nil ? ". Counts toward its limit." : ".")") {
                switch test {
                case .running: SettingsStatusChip(text: "Testing…", tint: .secondary, busy: true)
                case .ok(_, let ms, _): SettingsStatusChip(text: "Worked in \(ms) ms", tint: .green)
                case .failed(let reason): SettingsStatusChip(text: reason, tint: .orange)
                case .idle: EmptyView()
                }
                Button("Test") { runCommandTest(package, command, sample: sample) }
                    .buttonStyle(.bordered)
                    .disabled(blocked != nil || test == .running)
            }
            if case .ok(_, _, let lines) = test, let first = lines.first {
                Text(first).font(SettingsFont.sub).foregroundStyle(.secondary).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
            }
        }
    }

    private func runCommandTest(_ package: LassoPackage, _ command: PackageCommand, sample: String) {
        let s = store.settingValues(for: package)
        let entry = PackageRegistry.Entry(package: package, values: s.values, secrets: s.secrets, ready: true,
                                          places: store.places(for: package), fullAccess: store.hasFullAccess(package.id))
        test = .running
        let started = Date()
        Task {
            do {
                let input = command.input.contains(.args)
                    ? PackageInput(text: command.testArgs["text"], args: command.testArgs)
                    : PackageInput(text: command.testArgs["text"] ?? sample, args: command.testArgs)
                let result = try await PackageCommandRunner.run(entry, command, input: input)
                let text: String = if case .url(let url) = result { "Would open \(url.absoluteString)" }
                                   else { try await PackageOutput.text(result) }
                usageTick += 1
                test = .ok(count: 1, ms: Int(Date().timeIntervalSince(started) * 1000), hits: [String(text.prefix(600))])
            } catch {
                test = .failed(PackageOutput.failure(error, entry, command))
            }
        }
    }

    static func originText(_ origin: PackageStore.Origin) -> String {
        switch origin {
        case .bundled: "Built into Lasso"
        case .catalog: "From the Lasso catalog"
        case .file: "From a file"
        case .pasted: "Pasted"
        case .developer: "Developer mode"
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
            : store.missingSettings(package).first(where: { $0.kind == .folder }).map { "Choose its \($0.label.lowercased()) first." }
            ?? (!store.missingSettings(package).isEmpty ? "Fill in its settings first."
            : PackageRequirements.missingNow(package)
            ?? (!SearchQuota.canUse(package.id, limits: package.limits) ? "Limit reached." : nil))
        return SettingsCard(title: "Test") {
            SettingsRow("Test", caption: blocked ?? (command.script != nil ? "Searches your files for \"\(command.testQuery ?? "lasso")\"."
                                                     : "Searches for \"\(command.testQuery ?? "lasso")\". Counts as one search.")) {
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
        // With where its scripts run: without them a script search found nothing, in 5 ms.
        let entry = PackageRegistry.Entry(package: package, values: s.values, secrets: s.secrets, ready: true,
                                          places: store.places(for: package), fullAccess: store.hasFullAccess(package.id))
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
            if let previous = store.previousVersion(package.id) {
                SettingsRow("Version \(package.version) not working?", caption: "Go back to the version you had before. Its settings stay.") {
                    Button("Go back to \(previous)") {
                        do { try store.goBack(package.id) } catch { goBackError = error.localizedDescription }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let goBackError {
                Text(goBackError).font(SettingsFont.sub).foregroundStyle(.red).padding(.horizontal, SettingsMetrics.rowPaddingH)
            }
            SettingsRow("Remove \(package.name) from Lasso") {
                Button("Remove \(package.name)…", role: .destructive) { confirmRemove = true }.buttonStyle(.bordered)
            }
        }
        .confirmationDialog("Remove \(package.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove(package.id); removed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings, keys and data are deleted from this Mac. Files it saved in ~/LassoWorkspace and this month's usage count are kept.")
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
        case .folder:
            HStack(spacing: 8) {
                Text(text.isEmpty ? "None" : (text as NSString).abbreviatingWithTildeInPath)
                    .font(SettingsFont.sub).foregroundStyle(text.isEmpty ? .orange : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose the folder \(packageName) can read. It can't read anything else of yours."
                    if panel.runModal() == .OK, let url = panel.url {
                        text = url.path; commit()
                        // A first "What's in it" from the folder, unless the user wrote their own; then the
                        // package's own describe/1, if it has one, replaces Lasso's guess.
                        SourcePreferences.setAutomaticAbout(SourceAbout.suggest(for: url), packageID)
                        NotificationCenter.default.post(name: SourcePreferences.aboutChanged, object: packageID)
                        if let entry = PackageRegistry.shared.all.first(where: { $0.package.id == packageID }),
                           SourceDescribe.command(of: entry) != nil {
                            Task {
                                await SourceDescribe.refresh(entry)
                                NotificationCenter.default.post(name: SourcePreferences.aboutChanged, object: packageID)
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        case .text, .server:
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
