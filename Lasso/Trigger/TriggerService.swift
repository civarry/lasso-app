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
    }
}

extension KeyboardShortcuts.Name {
    static let capture = Self("capture", default: .init(.space, modifiers: [.option, .command]))
    static let cancelCapture = Self("cancelCapture", default: .init(.escape))
}
