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
        // No defaults — they stay inactive until the user assigns a key in Settings.
        KeyboardShortcuts.onKeyUp(for: .identifySelection) {
            CaptureCoordinator.shared.beginDirect(actionID: "identify")
        }
        KeyboardShortcuts.onKeyUp(for: .identifyFullScreen) {
            CaptureCoordinator.shared.beginFullScreen(actionID: "identify")
        }
        // Lens shortcuts honour the opt-in toggle AND local-only mode — the direct path skips the
        // action bar's `isRelevant` check, so it must re-check here or a hotkey would upload to Google
        // even with local-only on.
        KeyboardShortcuts.onKeyUp(for: .lensSelection) {
            guard Self.lensAllowed else { return }
            CaptureCoordinator.shared.beginDirect(actionID: "lens.search")
        }
        KeyboardShortcuts.onKeyUp(for: .lensFullScreen) {
            guard Self.lensAllowed else { return }
            CaptureCoordinator.shared.beginFullScreen(actionID: "lens.search")
        }

        // Fix grammar on the highlighted text, in place (reads the selection via ⌘C, pastes the
        // correction back) — no screenshot/OCR, no action bar.
        KeyboardShortcuts.onKeyUp(for: .grammarSelection) {
            GrammarFixService.shared.run()
        }
    }

    private static var lensAllowed: Bool {
        UserDefaults.standard.bool(forKey: LensSearchAction.enabledKey) && !PrivacyMode.localOnly
    }
}

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: .init(.space, modifiers: [.option, .command]))
    static let cancelCapture = Self("cancelCapture", default: .init(.escape))
    static let chat = Self("chat", default: .init(.a, modifiers: [.option, .command]))
    static let identifySelection = Self("identifySelection")
    static let identifyFullScreen = Self("identifyFullScreen")
    static let lensSelection = Self("lensSelection")
    static let lensFullScreen = Self("lensFullScreen")
    static let grammarSelection = Self("grammarSelection")
}
