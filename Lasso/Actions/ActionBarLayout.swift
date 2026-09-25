import Foundation

/// One entry the action bar can show, reduced to the three facts the layout actually needs: who it
/// is, where it ranks by default, and whether it can run for this selection.
///
/// The layout deliberately works over these instead of over `CaptureAction`. Two of the bar's
/// entries (Copy image / Save image) are built into the bar and are not registered actions at all,
/// and `CaptureAction` is `@MainActor` and cannot answer `isRelevant` without a real `CGImage`
/// context. Reducing both kinds to the same three facts is what lets the ordering rules below be a
/// plain function a test can drive without a screenshot.
struct ActionBarEntry: Equatable, Sendable {
    let id: String
    /// The shipped default rank (`CaptureAction.relevancePriority`). Only consulted for ids the
    /// user has never placed in their own order.
    let priority: Int
    /// False when the action is greyed for this selection (`disabledReason != nil`).
    var available: Bool = true

    init(id: String, priority: Int, available: Bool = true) {
        self.id = id
        self.priority = priority
        self.available = available
    }
}

/// Decides what the action bar shows, in what order, and what falls into the overflow menu.
///
/// The one rule that governs everything here: **the user's saved order wins**. Before this existed
/// the bar sorted purely by `relevancePriority`, so a QR code or a colour swatch in the selection
/// could shove the two actions someone actually uses out of reach. `relevancePriority` is now only
/// the fallback for ids the user has never touched, which is every id on a fresh install, so the
/// out-of-the-box bar is byte-for-byte what it was.
enum ActionBarLayout {

    /// The split the bar renders: `main` is the pill row, `overflow` is the "…" menu.
    struct Arrangement: Equatable, Sendable {
        var main: [ActionBarEntry] = []
        var overflow: [ActionBarEntry] = []

        /// The bar only grows an overflow control when there is something behind it. An always-present
        /// "…" that opens an empty menu is a dead affordance, which is worse than no affordance.
        var showsOverflowControl: Bool { !overflow.isEmpty }
    }

    /// Arrange `entries` for display.
    ///
    /// - Parameters:
    ///   - entries: every candidate entry, in registration order (the registry's own filtering by
    ///     `isRelevant` has already happened; entries that are merely *unavailable* are still here,
    ///     carrying `available == false`).
    ///   - order: the user's saved order, as action ids. Empty on a fresh install. Ids in here that
    ///     no longer exist are simply never matched, so a stale id cannot shift anything.
    ///   - hidden: ids the user switched off. These are **not** dropped: they move to the overflow
    ///     menu, so a hidden action is always one click away rather than gone.
    ///   - hideUnavailable: the existing "Hide unavailable actions" setting. It drops greyed entries
    ///     from the bar *and* the overflow menu, because an unavailable entry parked in a menu is
    ///     exactly the clutter that setting exists to remove.
    ///   - maxMain: cap on the pill row (Comfortable style caps at 6; Compact is icon-only and passes
    ///     nil). Anything past the cap spills into the overflow menu ahead of the hidden entries,
    ///     since it ranks higher in the user's own order.
    static func arrange(entries: [ActionBarEntry],
                        order: [String],
                        hidden: Set<String>,
                        hideUnavailable: Bool = false,
                        maxMain: Int? = nil) -> Arrangement {
        let candidates = hideUnavailable ? entries.filter(\.available) : entries

        // Position of each id in the user's order. A duplicate id keeps its first position; a saved
        // order should never be able to make one action occupy two slots.
        var userRank: [String: Int] = [:]
        for (position, id) in order.enumerated() where userRank[id] == nil {
            userRank[id] = position
        }

        // `sorted(by:)` is not guaranteed stable, so registration order is an explicit final
        // tie-break rather than something we hope the sort preserves.
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            switch (userRank[lhs.element.id], userRank[rhs.element.id]) {
            case let (l?, r?):
                return l == r ? lhs.offset < rhs.offset : l < r
            case (_?, nil):
                return true              // anything the user placed outranks anything they didn't
            case (nil, _?):
                return false
            case (nil, nil):
                // Never-ordered ids (a fresh install, or an action added by a later version) fall
                // back to the shipped ranking, which puts a new action in a predictable place at the
                // end of the user's order rather than at a random one.
                if lhs.element.priority != rhs.element.priority {
                    return lhs.element.priority < rhs.element.priority
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)

        var main = ranked.filter { !hidden.contains($0.id) }
        var overflow = ranked.filter { hidden.contains($0.id) }
        if let maxMain, main.count > maxMain {
            overflow = Array(main.dropFirst(maxMain)) + overflow
            main = Array(main.prefix(maxMain))
        }
        return Arrangement(main: main, overflow: overflow)
    }

    /// The full display order with nothing hidden or capped: what Settings lists, and what a reorder
    /// edits. Sharing `arrange` means the Settings list and the bar can never disagree about where an
    /// action sits.
    static func displayOrder(entries: [ActionBarEntry], order: [String]) -> [ActionBarEntry] {
        arrange(entries: entries, order: order, hidden: []).main
    }
}

/// Where the user's toolbar order and visibility live.
///
/// Plain `UserDefaults` string arrays, so they survive an app update and can be inspected with
/// `defaults read`. `revisionKey` exists only because `@AppStorage` cannot bind to an array: the bar
/// bumps off that integer to know it must re-read the two arrays.
enum ActionBarPreferences {
    static let orderKey = "actionBar.order"
    static let hiddenKey = "actionBar.hidden"
    static let revisionKey = "actionBar.revision"

    static func order(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: orderKey) ?? []
    }

    static func hidden(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    /// Commit an order + visibility pair. An empty `order` means "back to the shipped order" and is
    /// stored as an empty array rather than removed, so the intent is explicit in the defaults.
    static func save(order: [String], hidden: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: orderKey)
        defaults.set(hidden.sorted(), forKey: hiddenKey)
        defaults.set(defaults.integer(forKey: revisionKey) &+ 1, forKey: revisionKey)
    }
}
