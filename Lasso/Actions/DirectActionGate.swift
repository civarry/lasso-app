import Foundation

/// The single chokepoint that decides whether a direct hotkey may run an action.
///
/// **Why this type exists at all.** The direct path (`CaptureCoordinator.beginDirect` /
/// `beginFullScreen`) deliberately skips the action bar, and the action bar is where
/// `CaptureAction.isRelevant` runs. `isRelevant` is not cosmetic: it is where Lens's "this uploads
/// your screen to Google" opt-in and local-only mode are enforced. This app has shipped that hole
/// twice, patched both times with a `guard` copied into the one call site that was noticed. Nine
/// actions × two entry points is far too many call sites for that to keep working, so the check
/// moved to one function that every direct run passes through, and the function is pure so a test
/// can assert on it without a screenshot, a network, or a real provider.
///
/// The second half of the rule: when an action cannot run, **say so**. A hotkey that does nothing at
/// all is indistinguishable from a hotkey that isn't registered, and the user's next move is to
/// rebind a key that was working fine.
enum DirectActionGate {

    /// Everything the decision depends on, read once by the caller. Passed in rather than read from
    /// `UserDefaults` / the coordinator inside, so the rules are testable in isolation.
    struct Environment: Equatable, Sendable {
        /// Ids the registry currently knows. A saved hotkey can outlive the action it was bound to.
        var knownActionIDs: Set<String>
        /// Settings ▸ General ▸ Privacy ▸ "Search with Lens".
        var lensEnabled: Bool
        /// Settings ▸ General ▸ Privacy ▸ "Local-only mode".
        var localOnly: Bool
        /// `IntelligenceCoordinator.visionAvailable` — a local or cloud image model is usable.
        var visionAvailable: Bool
        /// A text request can actually be formed (`IntelligenceCoordinator.textModelConfigured`).
        var textModelConfigured: Bool
    }

    enum Decision: Equatable, Sendable {
        case allow
        /// Refused, with the card title and the sentence to show the user.
        case refuse(title: String, reason: String)

        var isAllowed: Bool { self == .allow }
    }

    /// Actions that cannot do anything without a working text model.
    static let textAIActionIDs: Set<String> = ["ai.ask", "ai.summarize", "ai.grammar"]

    /// Actions that need an image model.
    static let visionActionIDs: Set<String> = ["identify"]

    /// The second half of the gate, asked once the pre-pass has looked at the selection: is there
    /// anything here for this action to work on? `decide` runs before a pixel is captured and cannot
    /// answer this. Separate function, same rule: refuse out loud, never in silence.
    ///
    /// `disabledReason` wins over `isRelevant` because it is the more specific sentence ("No text to
    /// translate." beats "Translate has nothing to work with in that selection.").
    static func contentDecision(title: String, isRelevant: Bool, disabledReason: String?) -> Decision {
        if let disabledReason { return .refuse(title: title, reason: disabledReason) }
        guard isRelevant else {
            return .refuse(title: title, reason: "\(title) has nothing to work with in that selection.")
        }
        return .allow
    }

    /// - Parameter title: the action's display name, for the refusal card's heading. Falls back to
    ///   the app name for an id that no longer resolves to an action.
    static func decide(actionID: String, title: String = "Lasso",
                       environment env: Environment) -> Decision {
        guard env.knownActionIDs.contains(actionID) else {
            return .refuse(title: "Lasso",
                           reason: "That shortcut points at an action this version of Lasso no longer has. "
                                 + "Pick a different one in Settings ▸ General ▸ Toolbar actions.")
        }

        if actionID == "lens.search" {
            // Privacy first, and in this order: local-only is the stronger promise, so it is the
            // reason the user is shown even when Lens is also switched off.
            if env.localOnly {
                return .refuse(title: title,
                               reason: "Lens uploads the selection to Google, so it's paused in local-only mode. "
                                     + "Turn local-only mode off in Settings ▸ General ▸ Privacy to use it.")
            }
            if !env.lensEnabled {
                return .refuse(title: title,
                               reason: "Lens is off. It uploads the selection to Google, so you have to turn on "
                                     + "\"Search with Lens\" in Settings ▸ General ▸ Privacy first.")
            }
            return .allow
        }

        if visionActionIDs.contains(actionID), !env.visionAvailable {
            return .refuse(title: title,
                           reason: "\(title) needs an image model. Install Ollama, or pick one in "
                                 + "Settings ▸ Intelligence ▸ Image model.")
        }

        if textAIActionIDs.contains(actionID), !env.textModelConfigured {
            return .refuse(title: title,
                           reason: "\(title) needs a language model. Pick one in "
                                 + "Settings ▸ Intelligence ▸ Language model.")
        }

        return .allow
    }
}
