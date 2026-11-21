import Foundation

/// One edit a package makes to Lasso's own content (spec, "Patches: changing Lasso's own content").
struct PackagePatch: Sendable, Equatable {
    enum Op: String, Sendable, CaseIterable { case set, add, remove }
    var target: String
    var op: Op
    /// The text for a text target; the items for a list target (ids, or suggestion titles).
    var text: String?
    var items: [String] = []
}

/// What a package can patch in this version, and Lasso's defaults for each. `docs/patch-targets.md`
/// is generated from this list (a test fails when it's out of date), so the two can't disagree.
enum PatchTargets {
    enum Kind: Sendable, Equatable {
        /// Replaced whole by `set`.
        case text(max: Int)
        /// Lasso's toolbar ids, or `<package>/<command>`.
        case toolbarIDs
        /// Chat suggestion titles.
        case suggestions
        /// Text added after Lasso's own instructions, never replacing them.
        case instructions
    }

    struct Target: Sendable {
        var key: String
        var kind: Kind
        var ops: [PackagePatch.Op]
        var about: String
        /// Lasso's own value, for the docs and the review's Before.
        var defaultValue: String
    }

    /// Built-in actions whose prompt is plain instructions, with the selected text added by Lasso after
    /// it. Translate's and Identify's prompts ask for an exact output format Lasso then reads, so a
    /// change there would break them: they aren't patch targets.
    static let prompts: [(id: String, name: String, prompt: String)] = [
        ("ai.summarize", "Summarize", SummarizeAction.defaultPrompt),
        ("ai.grammar", "Proofread", GrammarFixAction.prompt),
    ]

    /// Built-in actions a package can rename, with their own names.
    static let titles: [(id: String, title: String)] = [
        ("ocr.copy", OCRCopyAction.defaultTitle), ("translate", TranslateAction.defaultTitle),
        ("ai.grammar", GrammarFixAction.defaultTitle), ("ai.summarize", SummarizeAction.defaultTitle),
        ("ai.ask", AskAIAction.defaultTitle), ("qr.open", QRAction.defaultTitle),
        ("color.pick", ColorPickerAction.defaultTitle), ("identify", IdentifyAction.defaultTitle),
        ("lens.search", LensSearchAction.defaultTitle),
    ]

    /// Ids a toolbar patch can name besides `<package>/<command>`.
    static var toolbarIDs: [String] {
        titles.map(\.id) + ["builtin.copyImage", "builtin.saveImage", "builtin.sendTo"]
    }

    static let maxSuggestionTitle = 60
    static let maxInstructions = 500
    static let maxPatches = 50
    /// The empty chat shows at most this many suggestions.
    static let maxSuggestionsShown = 6

    static var all: [Target] {
        prompts.map { Target(key: "action.\($0.id).prompt", kind: .text(max: 4000), ops: [.set],
                             about: "The instructions behind \($0.name). Lasso adds the text after them.",
                             defaultValue: $0.prompt) }
        + titles.map { Target(key: "action.\($0.id).title", kind: .text(max: 24), ops: [.set],
                              about: "The name of \($0.title) in the toolbar, menus and Settings.",
                              defaultValue: $0.title) }
        + [
            Target(key: "toolbar.order", kind: .toolbarIDs, ops: [.set],
                   about: "The toolbar's default order. An order you set in Settings › Toolbar comes first.",
                   defaultValue: "Lasso's own order"),
            Target(key: "toolbar.hidden", kind: .toolbarIDs, ops: [.set, .add, .remove],
                   about: "Toolbar buttons moved to the … menu by default, until you choose in Settings › Toolbar.",
                   defaultValue: "None"),
            Target(key: "chat.suggestions", kind: .suggestions, ops: [.set, .add, .remove],
                   about: "The suggestions on an empty chat (at most \(maxSuggestionsShown) show).",
                   defaultValue: ChatSuggestions.builtIn.joined(separator: "; ")),
            Target(key: "chat.instructions", kind: .instructions, ops: [.add],
                   about: "Text added after the chat model's own instructions, which always come first.",
                   defaultValue: "None"),
        ]
    }

    static func target(_ key: String) -> Target? { all.first { $0.key == key } }

    /// `docs/patch-targets.md`.
    static var markdown: String {
        var out = """
        # Patch targets

        Generated from `PatchTargets` in `Lasso/Packages/PackagePatches.swift` by `PatchTargetsDocTests`:
        don't edit by hand. What a package's `patches` can change, and Lasso's own value for each. The
        rules are in [PACKAGES.md](PACKAGES.md#patches-changing-lassos-own-content).

        | Target | Operations | What it is | Lasso's own |
        |---|---|---|---|

        """
        for t in all {
            let shown = t.defaultValue.count > 80 || t.defaultValue.contains("\n")
                ? "\(t.defaultValue.count.formatted()) characters, below" : t.defaultValue
            out += "| `\(t.key)` | \(t.ops.map { "`\($0.rawValue)`" }.joined(separator: ", ")) | \(t.about) | \(shown) |\n"
        }
        out += "\nToolbar ids: \(toolbarIDs.map { "`\($0)`" }.joined(separator: ", ")), or `<package>/<command>` for a package's button.\n"
        for p in prompts {
            out += "\n## `action.\(p.id).prompt`\n\n```text\n\(p.prompt)\n```\n"
        }
        return out
    }
}

/// The empty chat's suggestions Lasso ships with (`ChatView` gives them their actions by title).
enum ChatSuggestions {
    static let whatCanYouDo = "What can you do?"
    static let onScreen = "Ask about something on screen"
    static let attach = "Attach a file or image"
    static let builtIn = [whatCanYouDo, onScreen, attach]
}

// MARK: - Reading

extension PackagePatch {
    /// Reads a manifest's `patches`, adding every problem at its path.
    static func read(_ raw: Any, problem: (String, String) -> Void) -> [PackagePatch] {
        guard let list = raw as? [Any], (1...PatchTargets.maxPatches).contains(list.count) else {
            problem("patches", "Must be a list of 1 to \(PatchTargets.maxPatches) patches.")
            return []
        }
        var out: [PackagePatch] = []
        for (i, item) in list.enumerated() {
            let path = "patches[\(i)]"
            guard let o = item as? [String: Any] else { problem(path, "Must be an object."); continue }
            for key in o.keys.sorted() where !["target", "set", "add", "remove"].contains(key) {
                problem("\(path).\(key)", "Unknown field \"\(key)\".")
            }
            guard let key = o["target"] as? String else { problem("\(path).target", "Required: what to change."); continue }
            guard let target = PatchTargets.target(key) else {
                problem("\(path).target", "Lasso can't patch \"\(key)\". The list is in docs/patch-targets.md.")
                continue
            }
            let ops = PackagePatch.Op.allCases.filter { o[$0.rawValue] != nil }
            guard ops.count == 1, let op = ops.first else {
                problem(path, "Needs exactly one of: \(target.ops.map(\.rawValue).joined(separator: ", ")).")
                continue
            }
            guard target.ops.contains(op) else {
                problem("\(path).\(op.rawValue)", "\(key) can only be changed with \(target.ops.map(\.rawValue).joined(separator: " or ")).")
                continue
            }
            let at = "\(path).\(op.rawValue)"
            if let patch = value(o[op.rawValue]!, target: target, op: op, at: at, problem: problem) { out.append(patch) }
        }
        return out
    }

    private static func value(_ raw: Any, target: PatchTargets.Target, op: Op, at path: String,
                              problem: (String, String) -> Void) -> PackagePatch? {
        switch target.kind {
        case .text, .instructions:
            let max = if case .text(let m) = target.kind { m } else { PatchTargets.maxInstructions }
            guard let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                problem(path, "Must be text."); return nil
            }
            if text.count > max { problem(path, "At most \(max.formatted()) characters."); return nil }
            if target.key.hasSuffix(".prompt"), text.contains("{{") {
                problem(path, "Lasso adds the text after the prompt itself: leave out {{…}} values."); return nil
            }
            if target.key.hasSuffix(".title"), text.contains("\n") { problem(path, "Must be one line."); return nil }
            return PackagePatch(target: target.key, op: op, text: text)
        case .toolbarIDs:
            let ids: [String]
            if let one = raw as? String, op != .set { ids = [one] }
            else if let list = raw as? [String], !list.isEmpty { ids = list }
            else { problem(path, op == .set ? "Must be a list of toolbar ids." : "Must be a toolbar id or a list of them."); return nil }
            var bad = false
            for id in ids where !PatchTargets.toolbarIDs.contains(id) && !isPackageButton(id) {
                problem(path, "\"\(id)\" isn't a toolbar id: use \(PatchTargets.toolbarIDs.prefix(3).joined(separator: ", "))… or <package>/<command>.")
                bad = true
            }
            return bad ? nil : PackagePatch(target: target.key, op: op, items: ids)
        case .suggestions:
            var titles: [String] = []
            func title(_ item: Any, _ at: String) {
                // Removing names the suggestion by its title; adding gives an object, so more can follow.
                if op == .remove, let s = item as? String { titles.append(s); return }
                guard op != .remove, let o = item as? [String: Any] else {
                    problem(at, op == .remove ? "Must be a suggestion's title." : "Must be an object like {\"title\": \"…\"}."); return
                }
                for key in o.keys.sorted() where key != "title" { problem("\(at).\(key)", "Unknown field \"\(key)\".") }
                guard let t = o["title"] as? String, (1...PatchTargets.maxSuggestionTitle).contains(t.count), !t.contains("\n") else {
                    problem("\(at).title", "One line, 1 to \(PatchTargets.maxSuggestionTitle) characters."); return
                }
                titles.append(t)
            }
            if let list = raw as? [Any] {
                if list.isEmpty, op != .set { problem(path, "Must not be empty."); return nil }
                for (i, item) in list.enumerated() { title(item, "\(path)[\(i)]") }
            } else if op == .set {
                problem(path, "Must be a list of suggestions."); return nil
            } else {
                title(raw, path)
            }
            return PackagePatch(target: target.key, op: op, items: titles)
        }
    }

    static func isPackageButton(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
            && PackageValidator.matches(String(parts[0]), PackageValidator.idPattern)
            && PackageValidator.matches(String(parts[1]), PackageValidator.commandIDPattern)
    }

    /// A toolbar id as the bar knows it (`pkg:<package>/<command>` for a package's button).
    static func barID(_ id: String) -> String { isPackageButton(id) ? "pkg:\(id)" : id }
}

// MARK: - Applying

/// Every enabled package's patches applied over Lasso's defaults, in the user's patch order. Nothing is
/// written anywhere: turning a package off or removing it is undone by applying again without it.
struct AppliedPatches: Sendable, Equatable {
    /// `action.<id>.prompt` and `action.<id>.title` → value.
    var texts: [String: String] = [:]
    /// Nil when no package changes it.
    var toolbarOrder: [String]?
    var toolbarHidden: Set<String>?
    var suggestions: [String] = ChatSuggestions.builtIn
    var instructions: [(package: String, text: String)] = []
    /// For each target, every package that changes it, in the order they apply.
    var changedBy: [String: [String]] = [:]
    /// For targets one `set` replaces whole: the package whose value is in effect.
    var winner: [String: String] = [:]

    static func == (a: AppliedPatches, b: AppliedPatches) -> Bool {
        a.texts == b.texts && a.toolbarOrder == b.toolbarOrder && a.toolbarHidden == b.toolbarHidden
            && a.suggestions == b.suggestions && a.instructions.map(\.text) == b.instructions.map(\.text)
            && a.changedBy == b.changedBy && a.winner == b.winner
    }

    /// `packages` in patch order: later ones apply last, so a later `set` wins and `add`s accumulate.
    static func apply(_ packages: [LassoPackage]) -> AppliedPatches {
        var out = AppliedPatches()
        var hidden: [String] = []
        for package in packages {
            for patch in package.patches {
                if out.changedBy[patch.target]?.last != package.id { out.changedBy[patch.target, default: []].append(package.id) }
                switch patch.target {
                case "toolbar.order":
                    out.toolbarOrder = patch.items.map(PackagePatch.barID)
                    out.winner[patch.target] = package.id
                case "toolbar.hidden":
                    let ids = patch.items.map(PackagePatch.barID)
                    switch patch.op {
                    case .set: hidden = ids; out.winner[patch.target] = package.id
                    case .add: hidden += ids.filter { !hidden.contains($0) }
                    case .remove: hidden.removeAll { ids.contains($0) }
                    }
                    out.toolbarHidden = Set(hidden)
                case "chat.suggestions":
                    switch patch.op {
                    case .set: out.suggestions = patch.items; out.winner[patch.target] = package.id
                    case .add: out.suggestions += patch.items.filter { !out.suggestions.contains($0) }
                    case .remove: out.suggestions.removeAll { patch.items.contains($0) }
                    }
                case "chat.instructions":
                    if let text = patch.text { out.instructions.append((package.id, text)) }
                default:
                    out.texts[patch.target] = patch.text
                    out.winner[patch.target] = package.id
                }
            }
        }
        return out
    }
}

/// The patches in effect, readable from any thread (prompts are built off the main actor).
final class PatchState: @unchecked Sendable {
    static let shared = PatchState()
    private let lock = NSLock()
    private var applied = AppliedPatches()

    var current: AppliedPatches { lock.withLock { applied } }
    func update(_ new: AppliedPatches) { lock.withLock { applied = new } }

    static func prompt(_ actionID: String, default value: String) -> String {
        shared.current.texts["action.\(actionID).prompt"] ?? value
    }

    static func title(_ actionID: String, default value: String) -> String {
        shared.current.texts["action.\(actionID).title"] ?? value
    }

    /// Added after the chat model's own instructions, marked as coming from packages.
    static var chatInstructions: String? {
        let list = shared.current.instructions
        guard !list.isEmpty else { return nil }
        return "Added by packages the user installed:\n" + list.map { "- \($0.text)" }.joined(separator: "\n")
    }
}
