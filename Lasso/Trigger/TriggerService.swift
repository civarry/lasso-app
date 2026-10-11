import Foundation
import KeyboardShortcuts

/// Registers the global capture hotkey. Uses the `KeyboardShortcuts` package so Settings gets a
/// recorder UI for free (Spec §5). Default: ⌥⌘Space.
@MainActor
final class TriggerService {
    static let shared = TriggerService()
    private init() {}

    func setUp() {
        // Pressing the hotkey again while a session is active dismisses it (Circle-to-Search style).
        KeyboardShortcuts.onKeyUp(for: .capture) {
            CaptureCoordinator.shared.toggle()
        }
        // Esc cancels the active session. Registered as a global hotkey (reliable regardless of
        // which window has focus) but only enabled while a session is up — see CaptureCoordinator.
        KeyboardShortcuts.onKeyDown(for: .cancelCapture) {
            CaptureCoordinator.shared.cancel()
        }
        KeyboardShortcuts.disable(.cancelCapture)

        // Chat panel: separate global shortcut (default ⌥⌘A). Press again to dismiss.
        KeyboardShortcuts.onKeyUp(for: .chat) {
            ChatPanelController.shared.toggle()
        }

        // Direct-action shortcuts (Findit-style): skip the action bar and run one action immediately.
        // Every registered action gets one, derived from `ActionShortcuts.byActionID` rather than
        // listed here, so adding an action means editing that one table. No defaults — they stay
        // inactive until the user assigns a key in Settings.
        //
        // Skipping the bar also skips `CaptureAction.isRelevant`, which is where the Lens opt-in and
        // local-only mode are enforced. There is no per-shortcut guard here any more: every direct run
        // passes `CaptureCoordinator.passesDirectGate` → `DirectActionGate`, one chokepoint that also
        // tells the user *why* when it refuses.
        for (actionID, name) in ActionShortcuts.byActionID {
            KeyboardShortcuts.onKeyUp(for: name) {
                CaptureCoordinator.shared.beginDirect(actionID: actionID)
            }
        }
        for (actionID, name) in ActionShortcuts.fullScreenByActionID {
            KeyboardShortcuts.onKeyUp(for: name) {
                CaptureCoordinator.shared.beginFullScreen(actionID: actionID)
            }
        }

        // Proofread the highlighted text, in place (reads the selection via ⌘C, pastes the
        // correction back) — no screenshot/OCR, no action bar. Distinct from the toolbar's Proofread
        // action (`.grammarCapture`), which proofreads a dragged screen selection.
        KeyboardShortcuts.onKeyUp(for: .grammarSelection) {
            GrammarFixService.shared.run()
        }
    }
}

extension KeyboardShortcuts.Name {
    /// Human display for the effective shortcut — the user's custom binding if set, else the default —
    /// e.g. "⌃⇧C". `nil` only when there's neither (an unassigned action). Read this instead of
    /// hardcoding key combos in UI copy, which would lie once the user rebinds.
    @MainActor var displayString: String? { (shortcut ?? defaultShortcut)?.description }

    static let capture = Self("capture", default: .init(.c, modifiers: [.control, .shift]))
    static let cancelCapture = Self("cancelCapture", default: .init(.escape))
    static let chat = Self("chat", default: .init(.a, modifiers: [.control, .shift]))
    static let identifySelection = Self("identifySelection")            // no default — user assigns
    static let identifyFullScreen = Self("identifyFullScreen")          // no default — user assigns
    static let lensSelection = Self("lensSelection")                    // no default — user assigns
    static let lensFullScreen = Self("lensFullScreen")                  // no default — user assigns
    static let grammarSelection = Self("grammarSelection", default: .init(.g, modifiers: [.control, .shift]))
}
