import Foundation
import KeyboardShortcuts

/// The action id → hotkey-name mapping, and the toolbar catalog both the bar and Settings read.
///
/// Two things live here rather than in the views, and both for the same reason: adding an action
/// should mean touching `ActionRegistry.makeDefault` and this one table, not three files. The
/// `ActionShortcutsTests` coverage test fails the moment a registered action has no entry in
/// `byActionID`, so "forgot the hotkey" is a red test rather than a silently dead feature.
enum ActionShortcuts {

    /// Every registered action id and the `KeyboardShortcuts.Name` its "run this on a selection"
    /// hotkey is stored under.
    ///
    /// The names are storage keys: `identifySelection`, `lensSelection` and the full-screen pair
    /// predate this table and are kept verbatim, because renaming one would silently discard a
    /// binding the user already assigned.
    ///
    /// None of them ship a default. A default on nine actions would collide with whatever the user
    /// already has bound in other apps, and a hotkey that fires something they didn't ask for is
    /// worse than one they have to assign.
    static let byActionID: [String: KeyboardShortcuts.Name] = [
        "ocr.copy":     .ocrCopySelection,
        "translate":    .translateSelection,
        "ai.grammar":   .grammarCapture,
        "ai.summarize": .summarizeSelection,
        "ai.ask":       .askAISelection,
        "qr.open":      .qrSelection,
        "color.pick":   .colorPickSelection,
        "identify":     .identifySelection,
        "lens.search":  .lensSelection,
    ]

    /// The actions that also have a "grab the whole display, no drag" variant. Only the two visual
    /// lookups: a full-screen Copy text or Pick color has no sensible meaning.
    static let fullScreenByActionID: [String: KeyboardShortcuts.Name] = [
        "identify":    .identifyFullScreen,
        "lens.search": .lensFullScreen,
    ]

    static func name(for actionID: String) -> KeyboardShortcuts.Name? { byActionID[actionID] }

    /// Every shortcut Lasso owns, with the wording used when one collides with another.
    ///
    /// The library warns about a combination taken by macOS or by the app's menu bar, but says nothing
    /// when two of the app's *own* shortcuts are the same: both would then fire on one keypress, with
    /// no sign that anything was wrong. This table is what makes that warnable, and the coverage test
    /// keeps it complete.
    /// Lasso's own, plus every package hotkey command's (`pkg.<package>.<command>`), so a package's key
    /// that collides with Capture is warned about like any other.
    @MainActor
    static var titlesByName: [KeyboardShortcuts.Name: String] {
        var titles = builtInTitles
        for item in PackageRegistry.shared.commands(for: .hotkey) {
            titles[PackageHotkeys.name(item.entry.package.id, item.command.id)] = item.command.title
        }
        return titles
    }

    static let builtInTitles: [KeyboardShortcuts.Name: String] = [
        .capture: "Capture",
        .cancelCapture: "Cancel capture",
        .chat: "Chat",
        .grammarSelection: "Proofread highlighted text",
        .ocrCopySelection: "Copy text",
        .translateSelection: "Translate",
        .grammarCapture: "Proofread",
        .summarizeSelection: "Summarize",
        .askAISelection: "Ask AI",
        .qrSelection: "Scan code",
        .colorPickSelection: "Pick color",
        .identifySelection: "Identify",
        .lensSelection: "Google Lens",
        .identifyFullScreen: "Identify (full screen)",
        .lensFullScreen: "Google Lens (full screen)",
    ]
}

/// Shortcuts as staged edits.
///
/// Settings stages every control and applies it a moment after it changes; shortcuts used to be the one
/// exception, writing straight through to storage, so recording one left the panel claiming "All
/// changes saved" and Revert could not undo it. These two functions are the whole of the staging
/// rule, kept pure so the clearing case — a name the user emptied, which is a *missing* key rather
/// than a stored nil — is covered by a test rather than by clicking.
enum ShortcutStaging {

    /// What Settings loads into its draft: one entry per assigned shortcut, nothing for the rest.
    static func snapshot(names: some Sequence<KeyboardShortcuts.Name>,
                         stored: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?)
        -> [String: KeyboardShortcuts.Shortcut] {
        names.reduce(into: [:]) { staged, name in staged[name.rawValue] = stored(name) }
    }

    /// What applying must write: every name whose staged value differs from storage, paired with
    /// the value to write. A nil value means "clear this one", which is why the result is a list of
    /// pairs and not just the staged dictionary.
    static func changes(staged: [String: KeyboardShortcuts.Shortcut],
                        names: some Sequence<KeyboardShortcuts.Name>,
                        stored: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?)
        -> [(name: KeyboardShortcuts.Name, shortcut: KeyboardShortcuts.Shortcut?)] {
        names.sorted { $0.rawValue < $1.rawValue }       // deterministic, so a test can assert order
            .compactMap { name in
                let value = staged[name.rawValue]
                return value == stored(name) ? nil : (name, value)
            }
    }
}

/// Two of Lasso's own shortcuts set to the same keys.
@MainActor
enum ShortcutConflict {
    /// The other shortcut already using `proposed`, if any. `lookup` is injected so this stays a plain
    /// function over a table rather than something that can only be exercised by clicking.
    static func other(using proposed: KeyboardShortcuts.Shortcut, assignedTo name: KeyboardShortcuts.Name,
                      lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?) -> KeyboardShortcuts.Name? {
        ActionShortcuts.titlesByName.keys
            .filter { $0 != name }
            .sorted { $0.rawValue < $1.rawValue }        // stable answer when several somehow match
            .first { lookup($0) == proposed }
    }

    static func title(of name: KeyboardShortcuts.Name) -> String {
        ActionShortcuts.titlesByName[name] ?? name.rawValue
    }

    /// What the alert says. Names both sides, because "already in use" alone leaves the user hunting.
    static func message(proposed: KeyboardShortcuts.Shortcut, taking name: KeyboardShortcuts.Name,
                        from other: KeyboardShortcuts.Name) -> (title: String, body: String) {
        ("\(proposed.description) is already used by \(title(of: other))",
         "Keep it on \(title(of: other)), or move it to \(title(of: name)). "
         + "One combination can only run one thing.")
    }
}

extension KeyboardShortcuts.Name {
    static let ocrCopySelection = Self("ocrCopySelection")          // no default — user assigns
    static let translateSelection = Self("translateSelection")      // no default — user assigns
    static let summarizeSelection = Self("summarizeSelection")      // no default — user assigns
    static let askAISelection = Self("askAISelection")              // no default — user assigns
    static let qrSelection = Self("qrSelection")                    // no default — user assigns
    static let colorPickSelection = Self("colorPickSelection")      // no default — user assigns
    /// Proofread **a screen selection** (drag a box, OCR it, show the correction in a card). Distinct
    /// from `grammarSelection` (⌃⇧G), which proofreads already-highlighted text in place via ⌘C and
    /// pastes the correction back. Same action name, genuinely different jobs, so they get their own
    /// bindings instead of sharing one.
    static let grammarCapture = Self("grammarCapture")              // no default — user assigns
}

/// One row of the toolbar: a registered `CaptureAction`, or one of the two image actions the bar
/// builds in itself. Settings lists these to reorder, hide, and bind them; the bar renders them.
struct ActionBarCatalogEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let priority: Int
    /// nil for the built-in image actions: they are not in the registry, so the direct-capture path
    /// (`beginDirect(actionID:)`, which resolves the id against the registry) cannot run them.
    let shortcut: KeyboardShortcuts.Name?
    /// For a package's button: the package's name (and when it shows), the line under the title.
    var source: String?
}

@MainActor
enum ActionBarCatalog {
    /// Copy image / Save image. The bar has always appended these after the registered actions and
    /// they are part of what the user reorders and hides, so the definition lives here where both the
    /// bar and Settings can read it instead of being hardcoded in the view.
    static let builtIns: [ActionBarCatalogEntry] = [
        ActionBarCatalogEntry(id: "builtin.copyImage", title: "Copy image",
                              systemImage: "doc.on.doc", priority: 60, shortcut: nil),
        ActionBarCatalogEntry(id: "builtin.saveImage", title: "Save image",
                              systemImage: "square.and.arrow.down", priority: 61, shortcut: nil),
    ]

    /// Send to: a menu of package targets, in the bar only while at least one is enabled.
    static let sendTo = ActionBarCatalogEntry(id: "builtin.sendTo", title: "Send to", systemImage: "paperplane",
                                              priority: 62, shortcut: nil)

    /// Every toolbar row, in registration order: registered actions, the built-ins, Send to while there
    /// are targets, then package buttons.
    static func entries(actions: [any CaptureAction]) -> [ActionBarCatalogEntry] {
        let packages = PackageRegistry.shared.commands(for: .toolbar).map { PackageCommandAction(entry: $0.entry, command: $0.command) }
        return actions.map {
            ActionBarCatalogEntry(id: $0.id, title: $0.title, systemImage: $0.systemImage,
                                  priority: $0.relevancePriority, shortcut: ActionShortcuts.name(for: $0.id))
        } + builtIns
            + (PackageRegistry.shared.commands(for: .send).isEmpty ? [] : [sendTo])
            + packages.map {
                ActionBarCatalogEntry(id: $0.id, title: $0.title, systemImage: $0.systemImage, priority: $0.relevancePriority,
                                      shortcut: nil, source: $0.entry.package.name + Self.whenPhrase($0.command.when))
            }
    }

    /// ", when there's a tracking number" and so on: why a contextual button may not show.
    static func whenPhrase(_ when: PackageWhen?) -> String {
        guard let when else { return "" }
        let names = ["tracking": "a tracking number", "flight": "a flight number", "money": "an amount of money",
                     "link": "a link", "email": "an email address", "phone": "a phone number",
                     "address": "an address", "date": "a date", "table": "a table"]
        if let kind = when.detects.first, let name = names[kind] { return " · when there's \(name)" }
        if let min = when.minLength { return " · for text of \(min) characters or more" }
        if when.match != nil { return " · when the text matches a pattern" }
        if !when.apps.isEmpty { return " · in certain apps" }
        return ""
    }
}
