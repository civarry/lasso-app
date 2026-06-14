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
        // Lens shortcuts honour the opt-in toggle, so a stray hotkey can't upload without consent.
        KeyboardShortcuts.onKeyUp(for: .lensSelection) {
            guard Self.lensEnabled else { return }
            CaptureCoordinator.shared.beginDirect(actionID: "lens.search")
        }
        KeyboardShortcuts.onKeyUp(for: .lensFullScreen) {
            guard Self.lensEnabled else { return }
            CaptureCoordinator.shared.beginFullScreen(actionID: "lens.search")
        }
    }

    private static var lensEnabled: Bool {
        UserDefaults.standard.bool(forKey: LensSearchAction.enabledKey)
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
}
