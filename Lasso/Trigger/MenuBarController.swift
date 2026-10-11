import SwiftUI

/// The menu shown from the status-bar icon. Left-click opens this menu; "Capture Now" and the
/// global hotkey both start a session (Spec §5).
struct MenuBarController: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Now") {
            CaptureCoordinator.shared.begin()
        }

        Button("Open Chat") {
            ChatPanelController.shared.present()
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Lasso") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
