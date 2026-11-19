import SwiftUI

/// Lasso — on-device screen search for Apple Silicon Macs.
///
/// Menu-bar agent app (`LSUIElement`, `.accessory` policy). The hotkey and the menu both trigger
/// `CaptureCoordinator.begin()`. Wiring (registry, intelligence, login item) happens in
/// `AppDelegate.applicationDidFinishLaunching` to keep main-actor isolation clean.
@main
struct LassoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Lasso", systemImage: "lasso") {
            MenuBarController()
        }

        // A regular window, not SwiftUI's `Settings` scene: that one forces the old preferences toolbar
        // (title centred, controls on a row of their own, toolbar style ignored). This gets System
        // Settings' look: one row level with the traffic lights, ‹ › then the page title.
        Window("Settings", id: SettingsWindow.id) {
            SettingsView(intelligence: .shared)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
    }
}
