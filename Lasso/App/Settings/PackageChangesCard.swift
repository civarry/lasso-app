import SwiftUI

/// "What it changes in Lasso": a package's patches as sentences, in the review and on its page. Prompts
/// show Lasso's and the package's side by side on request; chat instructions always show in full,
/// since they're what a model is told. Where another package changes the same thing, it says which is
/// used, with a button to use this one.
struct PackageChangesCard: View {
    let package: LassoPackage
    /// The version it replaces or was approved as: what's new is tagged.
    var compareTo: LassoPackage?
    var store: PackageStore = .shared

    struct Line: Identifiable {
        var id: Int
        var symbol: String
        var text: String
        /// Lasso's and the package's prompt.
        var beforeAfter: (before: String, after: String)?
        /// Shown in full under the line.
        var quote: String?
        var tag: String?
        var patch: PackagePatch
    }

    var body: some View {
        let lines = Self.lines(package, compareTo: compareTo)
        SettingsCard(title: "What it changes in Lasso", footnote: footnote) {
            ForEach(lines) { line in row(line) }
            if let old = compareTo {
                let gone = old.patches.filter { o in !package.patches.contains { $0.target == o.target && $0.op == o.op } }
                ForEach(Array(gone.enumerated()), id: \.offset) { _, gone in
                    plain("minus.circle", "No longer: " + Self.sentence(gone, removed: true))
                }
            }
        }
    }

    private var footnote: String? {
        package.patches.contains { $0.target.hasPrefix("toolbar.") }
            ? "Your own toolbar order and choices in Settings › Toolbar still come first. Turn the package off to undo every change."
            : "Turn the package off to undo every change."
    }

    // MARK: Rows

    @ViewBuilder private func row(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: line.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(line.text).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let tag = line.tag {
                        Text(tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    }
                }
                if let quote = line.quote {
                    Text(quote).font(SettingsFont.label).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
                        .padding(.leading, 26)
                }
                if let pair = line.beforeAfter {
                    BeforeAfter(before: pair.before, after: pair.after).padding(.leading, 26)
                }
                conflict(line.patch).map { $0.padding(.leading, 26) }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)
            Divider()
        }
    }

    private func plain(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(text).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)
            Divider()
        }
    }

    /// Who wins where another enabled package replaces the same thing.
    private func conflict(_ patch: PackagePatch) -> AnyView? {
        guard patch.op == .set, patch.target != "chat.instructions" else { return nil }
        let applied = store.patches
        let others = (applied.changedBy[patch.target] ?? []).filter { $0 != package.id }
        guard let winner = applied.winner[patch.target], !others.isEmpty || winner != package.id else { return nil }
        let isInstalledHere = store.installed.contains { $0.id == package.id && $0.enabled }
        if !isInstalledHere {
            // In the review: installing makes this one the newest, so it's used.
            return AnyView(caption("Used instead of \(name(winner))'s."))
        }
        if winner == package.id {
            return AnyView(caption("\(ListFormatter.localizedString(byJoining: others.map(name))) also changes this. This one is used."))
        }
        return AnyView(HStack(spacing: 8) {
            caption("\(name(winner))'s is used instead.")
            Button("Use This One") { store.preferPatches(of: package.id) }
                .buttonStyle(.bordered).controlSize(.small)
        })
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(SettingsFont.sub).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func name(_ id: String) -> String { store.installed.first { $0.id == id }?.package.name ?? id }

    // MARK: Words

    static func lines(_ package: LassoPackage, compareTo old: LassoPackage?) -> [Line] {
        package.patches.enumerated().map { i, patch in
            var line = Line(id: i, symbol: symbol(patch.target), text: sentence(patch), patch: patch)
            if patch.target.hasSuffix(".prompt"), let text = patch.text {
                let id = String(patch.target.dropFirst("action.".count).dropLast(".prompt".count))
                line.beforeAfter = (PatchTargets.prompts.first { $0.id == id }?.prompt ?? "", text)
            }
            if patch.target == "chat.instructions" { line.quote = patch.text }
            if let old {
                if old.patches.contains(patch) { line.tag = nil }
                else if old.patches.contains(where: { $0.target == patch.target && $0.op == patch.op }) { line.tag = "Changed" }
                else { line.tag = "New" }
            }
            return line
        }
    }

    static func symbol(_ target: String) -> String {
        if target.hasSuffix(".prompt") { return "text.bubble" }
        if target.hasSuffix(".title") { return "character.cursor.ibeam" }
        if target.hasPrefix("toolbar.") { return "rectangle.3.group" }
        if target == "chat.instructions" { return "text.quote" }
        return "bubble.left.and.text.bubble.right"
    }

    /// One sentence for a patch. `removed` words it for "No longer: …".
    static func sentence(_ patch: PackagePatch, removed: Bool = false) -> String {
        let quoted = patch.items.map { "“\($0)”" }
        func and(_ list: [String]) -> String { ListFormatter.localizedString(byJoining: list) }
        switch patch.target {
        case "toolbar.order":
            return "Sets the toolbar's default order: " + patch.items.prefix(4).map(actionName).joined(separator: ", ")
                + (patch.items.count > 4 ? " and \(patch.items.count - 4) more" : "")
        case "toolbar.hidden":
            let names = and(patch.items.map(actionName))
            switch patch.op {
            case .set: return "Puts only \(names) in the toolbar's … menu"
            case .add: return "Moves \(names) to the toolbar's … menu"
            case .remove: return "Shows \(names) in the toolbar"
            }
        case "chat.suggestions":
            switch patch.op {
            case .set: return "Replaces the chat suggestions with \(patch.items.count == 1 ? "one" : "\(patch.items.count)") of its own: \(and(quoted))"
            case .add: return "Adds \(patch.items.count == 1 ? "the chat suggestion" : "chat suggestions") \(and(quoted))"
            case .remove: return "Removes \(patch.items.count == 1 ? "the chat suggestion" : "chat suggestions") \(and(quoted))"
            }
        case "chat.instructions":
            return removed ? "Adds to what the chat model is told" : "Adds to what the chat model is told:"
        case "chat.greeting": return "Changes the empty chat's greeting to “\(patch.text ?? "")”"
        case "chat.placeholder": return "Changes the message box's hint to “\(patch.text ?? "")”"
        default:
            let id = patch.target.split(separator: ".").dropFirst().dropLast().joined(separator: ".")
            let name = PatchTargets.titles.first { $0.id == id }?.title ?? id
            if patch.target.hasSuffix(".prompt") { return "Changes the \(name) prompt" }
            if patch.target.hasSuffix(".symbol") { return "Changes the icon of \(name)" }
            return "Renames \(name) to “\(patch.text ?? "")”"
        }
    }

    /// A toolbar id as people know it: "Lens", or a package button's title.
    static func actionName(_ id: String) -> String {
        if let title = PatchTargets.titles.first(where: { $0.id == id })?.title { return title }
        if let entry = (ActionBarCatalog.builtIns + [ActionBarCatalog.sendTo]).first(where: { $0.id == id }) { return entry.title }
        if PackagePatch.isPackageButton(id) {
            let parts = id.split(separator: "/").map(String.init)
            return PackageStore.shared.installed.first { $0.id == parts[0] }?.package.command(parts[1])?.title
                ?? "\(parts[1]) (from \(parts[0]))"
        }
        return id
    }
}

/// Lasso's prompt and a package's, folded until asked for.
private struct BeforeAfter: View {
    let before: String
    let after: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                Label(open ? "Hide Before and After" : "Show Before and After",
                      systemImage: open ? "chevron.down" : "chevron.right")
                    .font(SettingsFont.sub)
            }
            .buttonStyle(.borderless)
            if open {
                block("Lasso's", before)
                block("This package's", after)
            }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(SettingsFont.sub.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
