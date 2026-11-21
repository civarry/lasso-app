import SwiftUI

/// The menu shown from the status-bar icon. Left-click opens this menu; "Capture Now" and the
/// global hotkey both start a session (Spec §5).
struct MenuBarController: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = SettingsWindow.opener = openWindow
        Button("Capture Now") {
            CaptureCoordinator.shared.begin()
        }

        Button("Open Chat") {
            ChatPanelController.shared.present()
        }

        Divider()

        Button("Settings…") {
            SettingsWindow.open(with: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check for Updates…") {
            AppUpdater.shared.checkForUpdates()
        }
        .disabled(!AppUpdater.shared.canCheck)

        Button("Quit Lasso") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
